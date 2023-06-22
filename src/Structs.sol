// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

struct Pool {
    /// @notice address of the lender
    address lender;
    /// @notice address of the loan token
    address loanToken;
    /// @notice address of the collateral token
    address collateralToken;
    /// @notice the minimum size of the loan (to prevent griefing)
    uint256 minLoanSize;
    /// @notice the maximum size of the loan (also equal to the balance of the lender)
    uint256 poolBalance;
    /// @notice the max ratio of loanToken/collateralToken (multiplied by 10**18)
    uint256 maxLoanRatio;
    /// @notice the length of a refinance auction
    uint256 auctionLength;
    /// @notice the interest rate per year in BIPs
    uint256 interestRate;
}

struct Loan {
    /// @notice address of the lender
    address lender;
    /// @notice address of the borrower
    address borrower;
    /// @notice address of the loan token
    address loanToken;
    /// @notice address of the collateral token
    address collateralToken;
    /// @notice the amount borrowed
    uint256 debt;
    /// @notice the amount of collateral locked in the loan
    uint256 collateral;
    /// @notice the interest rate of the loan per second (in debt tokens)
    uint256 interestRate;
    /// @notice the timestamp of the loan start
    uint256 startTimestamp;
    /// @notice the timestamp of a refinance auction start
    uint256 auctionStartTimestamp;
    /// @notice the refinance auction length
    uint256 auctionLength;
}