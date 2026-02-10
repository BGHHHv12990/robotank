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
