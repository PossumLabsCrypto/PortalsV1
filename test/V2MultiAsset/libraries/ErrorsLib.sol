// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

library ErrorsLib {
    // ============================================
    // ==              CUSTOM ERRORS             ==
    // ============================================
    error InsufficientReceived();
    error InvalidAddress();
    error InvalidAmount();
    error DeadlineExpired();
    error InvalidConstructor();
    error DurationTooLow();
    error NativeTokenNotAllowed();
    error TokenExists();
    error EmptyAccount();
    error InsufficientBalance();
    error DurationLocked();
    error InsufficientToWithdraw();
    error InsufficientStakeBalance();

    error InactiveLP();
    error ActiveLP();
    error NotOwner();
    error PortalNotRegistered();
    error OwnerNotExpired();
    error FailedToSendNativeToken();
    error FundingPhaseOngoing();
    error FundingInsufficient();
    error TimeLockActive();
    error NoProfit();
    error OwnerRevoked();

    error NotOwnerOfNFT();
}
