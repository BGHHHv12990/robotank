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
