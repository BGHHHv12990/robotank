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
