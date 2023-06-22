// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./Errors.sol";
import "./Structs.sol";

import {IERC20} from "./IERC20.sol";
import {Ownable} from "./Ownable.sol";

contract Lender is Ownable {
    event PoolSet(bytes32 poolId);
    event Borrowed(uint256 loanId);
    event Repaid(uint256 loanId);
    event AuctionStart(uint256 loanId);
    event LoanBought(uint256 loanId);
    event LoanSiezed(uint256 loanId);
    event Refinanced(uint256 loanId);

    /// @notice the maximum interest rate is 1000%
    uint256 public constant MAX_INTEREST_RATE = 100000;
    /// @notice the maximum auction length is 3 days
    uint256 public constant MAX_AUCTION_LENGTH = 3 days;
    /// @notice the fee taken by the governance in BIPs
    uint256 public fee = 100;
    /// @notice the address of the fee receiver
    address public feeReceiver;

    /// @notice mapping of poolId to Pool (poolId is keccak256(lender, loanToken, collateralToken))
    mapping(bytes32 => Pool) public pools;
    Loan[] public loans;

    constructor() Ownable(msg.sender) {
        feeReceiver = msg.sender;
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         GOVERNANCE                         */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice set the fee
    /// can only be called by the owner
    /// @param _fee the new fee
    function setFee(uint256 _fee) external onlyOwner {
        if (_fee > 5000) revert FeeTooHigh();
        fee = _fee;
    }

    /// @notice set the fee receiver
    /// can only be called by the owner
    /// @param _feeReceiver the new fee receiver
    function setFeeReceiver(address _feeReceiver) external onlyOwner {
        feeReceiver = _feeReceiver;
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                        BASIC LOANS                         */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice set the info for a pool
    /// updates pool info for msg.sender
    /// @param poolInfo the new pool info
    function setPool(Pool calldata poolInfo) external {
        // validate the pool
        if (
            poolInfo.minLoanSize == 0 ||
            poolInfo.poolBalance == 0 ||
            poolInfo.maxLoanRatio == 0 ||
            poolInfo.auctionLength == 0 ||
            poolInfo.auctionLength > MAX_AUCTION_LENGTH ||
            poolInfo.interestRate > MAX_INTEREST_RATE
        ) revert PoolConfig();
        // set the pool
        bytes32 poolId = keccak256(
            abi.encode(
                poolInfo.lender,
                poolInfo.loanToken,
                poolInfo.collateralToken
            )
        );
        pools[poolId] = poolInfo;
        emit PoolSet(poolId);
    }

    /// @notice borrow a loan from a pool
    /// can be called by anyone
    /// @param poolId the id of the pool to borrow from
    /// @param debt the amount of debt to borrow
    /// @param collateral the amount of collateral to put up
    function borrow(bytes32 poolId, uint256 debt, uint256 collateral) public {
        // get the pool info
        Pool memory pool = pools[poolId];
        // validate the loan
        if (debt < pool.minLoanSize) revert LoanTooSmall();
        if (debt > pool.poolBalance) revert LoanTooLarge();
        // make sure the user isn't borrowing too much
        uint256 loanRatio = (debt * 10 ** 18) / collateral;
        if (loanRatio > pool.maxLoanRatio) revert RatioTooHigh();
        // create the loan
        Loan memory loan = Loan({
            lender: pool.lender,
            borrower: msg.sender,
            loanToken: pool.loanToken,
            collateralToken: pool.collateralToken,
            debt: debt,
            collateral: collateral,
            interestRate: pool.interestRate,
            startTimestamp: block.timestamp,
            auctionStartTimestamp: type(uint256).max,
            auctionLength: pool.auctionLength
        });
        // update the pool balance
        pools[poolId].poolBalance -= debt;
        // transfer the loan tokens from the lender to the borrower
        IERC20(loan.loanToken).transferFrom(pool.lender, msg.sender, debt);
        // transfer the collateral tokens from the borrower to the contract
        IERC20(loan.collateralToken).transferFrom(
            msg.sender,
            address(this),
            collateral
        );
        loans.push(loan);
        emit Borrowed(loans.length - 1);
    }

    /// @notice repay a loan
    /// can be called by anyone
    /// @param loanId the id of the loan to repay
    function repay(uint256 loanId) public {
        // get the loan info
        Loan memory loan = loans[loanId];
        // calculate the interest
        uint256 timeElapsed = block.timestamp - loan.startTimestamp;
        uint256 lenderInterest = ((loan.interestRate * loan.debt) / 10000) *
            (timeElapsed / 365 days);
        uint256 protocolInterest = ((fee * loan.debt) / 10000) *
            (timeElapsed / 365 days);
        // transfer the loan tokens from the borrower to the lender
        IERC20(loan.loanToken).transferFrom(
            msg.sender,
            loan.lender,
            loan.debt + lenderInterest
        );
        // transfer the protocol fee to the governance
        IERC20(loan.loanToken).transferFrom(
            msg.sender,
            feeReceiver,
            protocolInterest
        );
        // transfer the collateral tokens from the contract to the borrower
        IERC20(loan.collateralToken).transferFrom(
            address(this),
            loan.borrower,
            loan.collateral
        );
        // delete the loan
        delete loans[loanId];
        emit Repaid(loanId);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         REFINANCE                          */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice start a refinance auction
    /// can only be called by the lender
    /// @param loanId the id of the loan to refinance
    function startAuction(uint256 loanId) public {
        // get the loan info
        Loan memory loan = loans[loanId];
        // validate the loan
        if (msg.sender != loan.lender) revert Unauthorized();
        if (loan.auctionStartTimestamp != type(uint256).max) revert AuctionStarted();

        // set the auction start timestamp
        loans[loanId].auctionStartTimestamp = block.timestamp;
        emit AuctionStart(loanId);
    }

    /// @notice buy a loan in a refinance auction
    /// can be called by anyone
    /// @param loanId the id of the loan to refinance
    /// @param rate the interest rate the buyer is willing to accept
    function buyLoan(uint256 loanId, uint256 rate) public {
        // get the loan info
        Loan memory loan = loans[loanId];
        // validate the loan
        if (loan.auctionStartTimestamp == type(uint256).max) revert AuctionNotStarted();
        if (block.timestamp > loan.auctionStartTimestamp + loan.auctionLength) revert AuctionEnded();
        // calculate the current interest rate
        uint256 timeElapsed = block.timestamp - loan.auctionStartTimestamp;
        uint256 currentAuctionRate = (MAX_INTEREST_RATE * timeElapsed) /
            loan.auctionLength;
        // validate the rate
        if (rate > currentAuctionRate) revert RateTooHigh();
        // calculate the interest
        uint256 lenderInterest = ((rate * loan.debt) / 10000) *
            (timeElapsed / 365 days);
        uint256 protocolInterest = ((fee * loan.debt) / 10000) *
            (timeElapsed / 365 days);
        // transfer the loan tokens from the buyer to the lender
        IERC20(loan.loanToken).transferFrom(
            msg.sender,
            loan.lender,
            loan.debt + lenderInterest
        );
        // transfer the protocol fee to the governance
        IERC20(loan.loanToken).transferFrom(
            msg.sender,
            feeReceiver,
            protocolInterest
        );
        // update the loan with the new info
        loans[loanId].lender = msg.sender;
        loans[loanId].interestRate = rate;
        loans[loanId].startTimestamp = block.timestamp;
        loans[loanId].auctionStartTimestamp = type(uint256).max;
        loans[loanId].debt = loan.debt + lenderInterest + protocolInterest;
        emit LoanBought(loanId);
    }

    /// @notice sieze a loan after a failed refinance auction
    /// can be called by anyone
    /// @param loanId the id of the loan to sieze
    function siezeLoan(uint256 loanId) public {
        // get the loan info
        Loan memory loan = loans[loanId];
        // validate the loan
        if (loan.auctionStartTimestamp == type(uint256).max) revert AuctionNotStarted();
        if (block.timestamp < loan.auctionStartTimestamp + loan.auctionLength) revert AuctionNotEnded();
        // calculate the fee
        uint256 govFee = (fee * loan.collateral) / 10000;
        // transfer the protocol fee to governance
        IERC20(loan.collateralToken).transferFrom(
            address(this),
            feeReceiver,
            govFee
        );
        // transfer the collateral tokens from the contract to the lender
        IERC20(loan.collateralToken).transferFrom(
            address(this),
            loan.lender,
            loan.collateral - govFee
        );
        // delete the loan
        delete loans[loanId];
        emit LoanSiezed(loanId);
    }

    /// @notice refinance a loan to a new offer
    /// can only be called by the borrower
    /// @param loanId the id of the loan to refinance
    /// @param poolId the id of the pool to refinance to
    /// @param debt the new amount of debt
    /// @param collateral the new amount of collateral
    function refinance(
        uint256 loanId,
        bytes32 poolId,
        uint256 debt,
        uint256 collateral
    ) public {
        // get the loan info
        Loan memory loan = loans[loanId];
        // validate the loan
        if (msg.sender != loan.borrower) revert Unauthorized();
        // get the pool info
        Pool memory pool = pools[poolId];
        // validate the new loan
        if (pool.loanToken != loan.loanToken) revert TokenMismatch();
        if (pool.collateralToken != loan.collateralToken) revert TokenMismatch();
        if (pool.poolBalance < debt) revert LoanTooLarge();
        if (debt < pool.minLoanSize) revert LoanTooSmall();
        uint256 loanRatio = (debt * 10 ** 18) / collateral;
        if (loanRatio > pool.maxLoanRatio) revert RatioTooHigh();
        // calculate the interest
        uint256 timeElapsed = block.timestamp - loan.startTimestamp;
        uint256 lenderInterest = ((loan.interestRate * loan.debt) / 10000) *
            (timeElapsed / 365 days);
        uint256 protocolInterest = ((fee * loan.debt) / 10000) *
            (timeElapsed / 365 days);
        uint256 debtToPay = loan.debt + lenderInterest + protocolInterest;

        // first lets take our tokens from the new pool
        IERC20(loan.loanToken).transferFrom(
            pool.lender,
            address(this),
            debt
        );

        if (debtToPay > debt) {
            // we owe more in debt so we need the borrower to give us more loan tokens
            // transfer the loan tokens from the borrower to the contract
            IERC20(loan.loanToken).transferFrom(
                msg.sender,
                address(this),
                debtToPay - debt
            );
        } else if (debtToPay < debt) {
            // we have excess loan tokens so we give some back to the borrower
            // transfer the loan tokens from the contract to the borrower
            IERC20(loan.loanToken).transferFrom(
                address(this),
                msg.sender,
                debt - debtToPay
            );
        }

        // transder loanTokens to old lender and gov from new lender
        IERC20(loan.loanToken).transfer(
            loan.lender,
            loan.debt + lenderInterest
        );
        IERC20(loan.loanToken).transfer(
            feeReceiver,
            protocolInterest
        );

        // update loan debt
        loans[loanId].debt = debt;
        // update loan collateral
        if (collateral > loan.collateral) {
            // transfer the collateral tokens from the borrower to the contract
            IERC20(loan.collateralToken).transferFrom(
                msg.sender,
                address(this),
                collateral - loan.collateral
            );
        } else if (collateral < loan.collateral) {
            // transfer the collateral tokens from the contract to the borrower
            IERC20(loan.collateralToken).transfer(
                msg.sender,
                loan.collateral - collateral
            );
        }
        loans[loanId].collateral = collateral;
        // update loan interest rate
        loans[loanId].interestRate = pool.interestRate;
        // update loan start timestamp
        loans[loanId].startTimestamp = block.timestamp;
        // update loan auction start timestamp
        loans[loanId].auctionStartTimestamp = type(uint256).max;
        // update loan auction length
        loans[loanId].auctionLength = pool.auctionLength;
        // update loan lender
        loans[loanId].lender = pool.lender;
        // update pool balance
        pools[poolId].poolBalance -= debt;
        emit Refinanced(loanId);
    }
}
