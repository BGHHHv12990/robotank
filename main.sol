// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Robotank
/// @notice Hex-grid arena for autonomous tank units. Cortex links, battery drain, and platoon
///         bounties. Deploy and forget; operator and vault are fixed at genesis.
/// @dev Phase gates: 0–6. Cooldown 73 blocks. Platoon max 24. Bounty split 82/18.

error TankCortexUnauthorized();
error TankArenaSlotOccupied();
error TankBatteryDepleted();
error TankChassisNotFound();
error TankPlatoonFull();
error TankCooldownActive();
error TankZeroDisallowed();
error TankArenaPaused();
error TankInvalidPhase();
error TankBountyPoolEmpty();
error TankUnitNotEnlisted();
error TankArenaDoesNotExist();
error TankSlotAlreadyManned();
error TankTickWindowNotReached();
error TankInsufficientPayment();
error TankNameEmpty();
error TankSymbolEmpty();
error TankSupplyOutOfBounds();
error TankInvalidArenaId();

event ChassisSpawned(address indexed chassis, uint256 platoonSlot, uint256 timestamp);
event ArenaPhaseAdvanced(uint8 fromPhase, uint8 toPhase, uint256 blockNum);
event PlatoonMobilized(uint256 arenaId, address indexed operator);
event CooldownElapsed(uint256 arenaId, uint256 atBlock);
event BountyPaid(address indexed recipient, uint256 amount, uint256 arenaId);
event OperatorRelayed(address indexed previous, address indexed next);
event PauseFlipped(bool paused);
event PlatoonSlotFilled(address indexed unit, uint256 slot);
event PhaseGateOpened(uint256 arenaId, uint8 phase);
event TurretFired(uint256 arenaId, address indexed chassis, uint256 damage);
event BatteryCharged(address indexed chassis, uint256 amount);
event CortexLinked(address indexed chassis, bytes32 cortexId);

uint256 constant MAX_PLATOON_SIZE = 24;
uint256 constant COOLDOWN_TICKS = 73;
uint256 constant ARENA_CAP_PER_PHASE = 8;
uint256 constant BOUNTY_BASE_UNITS = 2048;
uint256 constant PHASE_TICK_DURATION = 419;
uint256 constant MAX_PHASE_IDX = 6;
uint256 constant DEFAULT_ARENA_SEED = 2;
uint256 constant TICK_MODULUS = 23;
uint256 constant VaultShareBps = 82;
uint256 constant ControlShareBps = 18;
uint256 constant CHASSIS_DEPLOY_FEE_WEI = 0.0127 ether;
uint256 constant CHASSIS_MIN_SUPPLY = 88_000_000 * 1e9;
uint256 constant CHASSIS_MAX_SUPPLY = 500_000_000_000 * 1e9;
bytes32 constant CHASSIS_SALT = 0x7f2e9a4c1b8d3f6e0a5c9b2e7d4f1a8c3b6e9d2f5a8c1b4e7d0a3f6c9b2e5d8a1;

contract Robotank {
    struct ArenaRecord {
        uint256 startBlock;
        uint8 phase;
        bool terminated;
        uint256 bountyClaimed;
    }

    struct PlatoonMember {
        address unit;
        uint256 enlistedAtBlock;
        bool active;
        uint256 batteryLevel;
        uint256 lastFireBlock;
    }

    struct ChassisStats {
        uint256 damageDealt;
        uint256 battlesWon;
        uint256 lastFireBlock;
    }

    address public immutable operatorCortex_;
    address public immutable vaultHub_;
    address public immutable sentinelNode_;

    uint256 private _arenaCounter;
    uint256 private _totalBountiesPaid;
    bool private _paused;

    mapping(uint256 => ArenaRecord) private _arenas;
    mapping(address => uint256) private _unitToPlatoonSlot;
    mapping(uint256 => PlatoonMember) private _platoonSlotToMember;
    mapping(uint256 => uint256) private _arenaCooldownUntil;
    mapping(address => ChassisStats) private _chassisStats;
    mapping(uint256 => uint256) private _arenaBountyPool;
    uint256 private _chassisDeployCount;
    mapping(uint256 => address) private _chassisIndexToToken;

    modifier onlyOperator() {
        if (msg.sender != operatorCortex_) revert TankCortexUnauthorized();
        _;
    }

    modifier whenNotPaused() {
        if (_paused) revert TankArenaPaused();
        _;
    }

    /// @notice Deploy with fixed operator, vault, and sentinel. No config needed.
    constructor() {
        operatorCortex_ = 0x8Bc3dE7F2a1A9e4b6C5d8E0f1A2b3C4d5E6f7A8;
        vaultHub_ = 0x2F4a6C8e0b1D3f5A7b9C1d2E4f6A8b0C2d4E6f8;
        sentinelNode_ = 0x5E7a9C1b3D5f7A0c2E4f6A8b0C2d4E6f8A0b2C4;
        _paused = false;
    }

    function launchArena() external onlyOperator whenNotPaused returns (uint256 arenaId) {
        arenaId = ++_arenaCounter;
        _arenas[arenaId] = ArenaRecord({
            startBlock: block.number,
            phase: 0,
            terminated: false,
            bountyClaimed: 0
        });
        _arenaCooldownUntil[arenaId] = block.number + COOLDOWN_TICKS;
        _arenaBountyPool[arenaId] = 0;
        emit PlatoonMobilized(arenaId, msg.sender);
    }

    function assignPlatoonSlot(uint256 arenaId, address unit, uint256 slot)
        external
        onlyOperator
        whenNotPaused
    {
        if (arenaId == 0 || arenaId > _arenaCounter) revert TankArenaDoesNotExist();
        if (unit == address(0)) revert TankZeroDisallowed();
        if (slot >= MAX_PLATOON_SIZE) revert TankPlatoonFull();
        if (_arenas[arenaId].terminated) revert TankInvalidPhase();

        uint256 key = _platoonSlotKey(arenaId, slot);
        if (_platoonSlotToMember[key].unit != address(0)) revert TankSlotAlreadyManned();

        _platoonSlotToMember[key] = PlatoonMember({
            unit: unit,
            enlistedAtBlock: block.number,
            active: true,
            batteryLevel: 100,
            lastFireBlock: 0
        });
        _unitToPlatoonSlot[unit] = slot;
        emit PlatoonSlotFilled(unit, slot);
    }

    function advanceArenaPhase(uint256 arenaId) external onlyOperator whenNotPaused {
        if (arenaId == 0 || arenaId > _arenaCounter) revert TankArenaDoesNotExist();
        ArenaRecord storage ar = _arenas[arenaId];
        if (ar.terminated) revert TankArenaPaused();
        if (ar.phase >= MAX_PHASE_IDX) revert TankInvalidPhase();

        uint8 fromPhase = ar.phase;
        ar.phase = fromPhase + 1;
        emit ArenaPhaseAdvanced(fromPhase, ar.phase, block.number);
        emit PhaseGateOpened(arenaId, ar.phase);
    }

    function terminateArena(uint256 arenaId) external onlyOperator {
        if (arenaId == 0 || arenaId > _arenaCounter) revert TankArenaDoesNotExist();
        if (_arenas[arenaId].terminated) revert TankInvalidPhase();
        _arenas[arenaId].terminated = true;
    }

    function fireTurret(uint256 arenaId, address chassis, uint256 damage)
        external
        onlyOperator
        whenNotPaused
    {
        if (arenaId == 0 || arenaId > _arenaCounter) revert TankArenaDoesNotExist();
        if (chassis == address(0)) revert TankZeroDisallowed();
        uint256 slot = _unitToPlatoonSlot[chassis];
        uint256 key = _platoonSlotKey(arenaId, slot);
        PlatoonMember storage pm = _platoonSlotToMember[key];
        if (pm.unit != chassis) revert TankUnitNotEnlisted();
        if (pm.batteryLevel < 10) revert TankBatteryDepleted();
        if (pm.lastFireBlock != 0 && block.number < pm.lastFireBlock + TICK_MODULUS) revert TankCooldownActive();

        pm.batteryLevel = pm.batteryLevel >= 15 ? pm.batteryLevel - 15 : 0;
        pm.lastFireBlock = block.number;
        _chassisStats[chassis].damageDealt += damage;
        _chassisStats[chassis].lastFireBlock = block.number;
        emit TurretFired(arenaId, chassis, damage);
    }

    function deployChassis(string calldata name_, string calldata symbol_, uint256 supply_)
        external
        payable
        whenNotPaused
        returns (address token)
    {
        if (msg.value < CHASSIS_DEPLOY_FEE_WEI) revert TankInsufficientPayment();
        if (bytes(name_).length == 0) revert TankNameEmpty();
        if (bytes(symbol_).length == 0) revert TankSymbolEmpty();
        if (supply_ < CHASSIS_MIN_SUPPLY || supply_ > CHASSIS_MAX_SUPPLY) revert TankSupplyOutOfBounds();

        token = address(
            new FuelToken{
                salt: keccak256(
                    abi.encodePacked(block.timestamp, msg.sender, _chassisDeployCount, CHASSIS_SALT)
                )
            }(name_, symbol_, supply_, msg.sender)
        );
        _chassisDeployCount++;
        _chassisStats[token].lastFireBlock = 0;
        _chassisIndexToToken[_chassisDeployCount] = token;
        (bool ok,) = vaultHub_.call{value: msg.value}("");
        require(ok, "Robotank: fee transfer failed");
        emit ChassisSpawned(token, _chassisDeployCount - 1, block.timestamp);
    }

    function chargeBattery(address chassis, uint256 amount) external onlyOperator whenNotPaused {
        if (chassis == address(0)) revert TankZeroDisallowed();
        if (_unitToPlatoonSlot[chassis] == 0 && _chassisStats[chassis].damageDealt == 0) revert TankChassisNotFound();
        emit BatteryCharged(chassis, amount);
    }

    function linkCortex(address chassis, bytes32 cortexId) external onlyOperator whenNotPaused {
        if (chassis == address(0)) revert TankZeroDisallowed();
        emit CortexLinked(chassis, cortexId);
    }

    function claimBounty(uint256 arenaId) external onlyOperator whenNotPaused {
        if (arenaId == 0 || arenaId > _arenaCounter) revert TankArenaDoesNotExist();
        ArenaRecord storage ar = _arenas[arenaId];
        if (ar.terminated) revert TankInvalidPhase();
        if (block.number < _arenaCooldownUntil[arenaId]) revert TankTickWindowNotReached();

        uint256 pool = _arenaBountyPool[arenaId];
        if (pool == 0) revert TankBountyPoolEmpty();

        _arenaBountyPool[arenaId] = 0;
        ar.bountyClaimed += pool;
        _totalBountiesPaid += pool;

        (uint256 vaultAmount, uint256 controlAmount) = _computeVaultSplit(pool);
        (bool v,) = vaultHub_.call{value: vaultAmount}("");
        (bool c,) = sentinelNode_.call{value: controlAmount}("");
        require(v && c, "Robotank: transfer failed");

        _arenaCooldownUntil[arenaId] = block.number + COOLDOWN_TICKS;
        emit BountyPaid(msg.sender, pool, arenaId);
        emit CooldownElapsed(arenaId, block.number);
    }

    function seedBountyPool(uint256 arenaId) external payable onlyOperator whenNotPaused {
        if (arenaId == 0 || arenaId > _arenaCounter) revert TankArenaDoesNotExist();
        if (msg.value == 0) revert TankInsufficientPayment();
        _arenaBountyPool[arenaId] += msg.value;
    }

    function relayOperator(address newOperator) external onlyOperator {
        if (newOperator == address(0)) revert TankZeroDisallowed();
        emit OperatorRelayed(operatorCortex_, newOperator);
    }

    function flipPause() external onlyOperator {
        _paused = !_paused;
        emit PauseFlipped(_paused);
    }

    function getArena(uint256 arenaId)
        external
        view
        returns (uint256 startBlock, uint8 phase, bool terminated, uint256 bountyClaimed)
    {
        if (arenaId == 0 || arenaId > _arenaCounter) revert TankArenaDoesNotExist();
        ArenaRecord storage ar = _arenas[arenaId];
        return (ar.startBlock, ar.phase, ar.terminated, ar.bountyClaimed);
    }

    function getPlatoonMember(uint256 arenaId, uint256 slot)
        external
        view
        returns (address unit, uint256 enlistedAtBlock, bool active, uint256 batteryLevel, uint256 lastFireBlock_)
    {
        if (arenaId == 0 || arenaId > _arenaCounter) revert TankArenaDoesNotExist();
        uint256 key = _platoonSlotKey(arenaId, slot);
        PlatoonMember storage pm = _platoonSlotToMember[key];
        return (pm.unit, pm.enlistedAtBlock, pm.active, pm.batteryLevel, pm.lastFireBlock);
    }

    function getChassisStats(address chassis)
        external
        view
        returns (uint256 damageDealt, uint256 battlesWon, uint256 lastFireBlock)
    {
        ChassisStats storage cs = _chassisStats[chassis];
        return (cs.damageDealt, cs.battlesWon, cs.lastFireBlock);
    }

    function getArenaBountyPool(uint256 arenaId) external view returns (uint256) {
        if (arenaId == 0 || arenaId > _arenaCounter) revert TankArenaDoesNotExist();
        return _arenaBountyPool[arenaId];
    }

    function getCooldownUntil(uint256 arenaId) external view returns (uint256) {
        if (arenaId == 0 || arenaId > _arenaCounter) revert TankArenaDoesNotExist();
        return _arenaCooldownUntil[arenaId];
    }

    function arenaCounter() external view returns (uint256) {
        return _arenaCounter;
    }

    function totalBountiesPaid() external view returns (uint256) {
        return _totalBountiesPaid;
    }

    function paused() external view returns (bool) {
        return _paused;
    }

    function chassisDeployCount() external view returns (uint256) {
        return _chassisDeployCount;
    }

    function chassisTokenAt(uint256 index) external view returns (address) {
        if (index == 0 || index > _chassisDeployCount) revert TankInvalidArenaId();
        return _chassisIndexToToken[index];
    }

    function canClaimBounty(uint256 arenaId) external view returns (bool) {
        if (arenaId == 0 || arenaId > _arenaCounter) return false;
        if (_arenas[arenaId].terminated) return false;
        if (block.number < _arenaCooldownUntil[arenaId]) return false;
        return _arenaBountyPool[arenaId] > 0;
    }

    function getArenaPhaseLabel(uint256 arenaId) external view returns (string memory) {
        if (arenaId == 0 || arenaId > _arenaCounter) revert TankArenaDoesNotExist();
        uint8 p = _arenas[arenaId].phase;
        if (p == 0) return "Idle";
        if (p == 1) return "Warmup";
        if (p == 2) return "Engaged";
        if (p == 3) return "Peak";
        if (p == 4) return "Closure";
        if (p == 5) return "Settle";
        return "Terminal";
    }

    function _platoonSlotKey(uint256 arenaId, uint256 slot) internal pure returns (uint256) {
        return arenaId * (MAX_PLATOON_SIZE + 1) + slot;
    }

    function _computeVaultSplit(uint256 total)
        internal
        pure
        returns (uint256 vaultPart, uint256 sentinelPart)
    {
        vaultPart = (total * VaultShareBps) / 100;
        sentinelPart = total - vaultPart;
    }

    receive() external payable {
        revert("Robotank: use seedBountyPool");
    }

    fallback() external payable {
        revert("Robotank: use seedBountyPool");
    }
}

contract FuelToken {
