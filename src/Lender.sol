// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./Errors.sol";
import "./Structs.sol";

import {IERC20} from "./IERC20.sol";
import {Ownable} from "./Ownable.sol";

contract Lender is Ownable {
    event PoolCreated(bytes32 indexed poolId, Pool pool);
    event PoolUpdated(bytes32 indexed poolId, Pool pool);
    event PoolBalanceUpdated(bytes32 indexed poolId, uint256 newBalance);
    event Borrowed(
        address indexed borrower,
        address indexed lender,
        uint256 indexed loanId,
        uint256 debt,
        uint256 collateral,
        uint256 interestRate,
        uint256 startTimestamp
    );
    event Repaid(
        address indexed borrower,
        address indexed lender,
        uint256 indexed loanId,
        uint256 debt,
        uint256 collateral,
        uint256 interestRate,
        uint256 startTimestamp
    );
    event AuctionStart(
        address indexed borrower,
        address indexed lender,
        uint256 indexed loanId,
        uint256 debt,
        uint256 collateral,
        uint256 auctionStartTime,
        uint256 auctionLength
    );
    event LoanBought(uint256 loanId);
    event LoanSiezed(
        address indexed borrower,
        address indexed lender,
        uint256 indexed loanId,
        uint256 collateral
    );
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
    /*                         LOAN INFO                          */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function getLoanDebt(uint256 loanId) external view returns (uint256 debt) {
        Loan memory loan = loans[loanId];
        // calculate the accrued interest
        uint256 timeElapsed = block.timestamp - loan.startTimestamp;
        uint256 interest = ((loan.interestRate * loan.debt) / 10000) *
            (timeElapsed / 365 days);
        uint256 fees = ((fee * loan.debt) / 10000) * (timeElapsed / 365 days);
        debt = loan.debt + interest + fees;
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                        BASIC LOANS                         */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice set the info for a pool
    /// updates pool info for msg.sender
    /// @param poolInfo the new pool info
    function setPool(Pool calldata poolInfo) external returns (bytes32 poolId) {
        // validate the pool
        if (
            poolInfo.lender != msg.sender ||
            poolInfo.minLoanSize == 0 ||
            poolInfo.maxLoanRatio == 0 ||
            poolInfo.auctionLength == 0 ||
            poolInfo.auctionLength > MAX_AUCTION_LENGTH ||
            poolInfo.interestRate > MAX_INTEREST_RATE
        ) revert PoolConfig();

        // check if they already have a pool balance
        poolId = keccak256(
            abi.encode(
                poolInfo.lender,
                poolInfo.loanToken,
                poolInfo.collateralToken
            )
        );
        uint256 currentBalance = pools[poolId].poolBalance;

        if (poolInfo.poolBalance > currentBalance) {
            // if new balance > current balance then transfer the difference from the lender
            IERC20(poolInfo.loanToken).transferFrom(
                poolInfo.lender,
                address(this),
                poolInfo.poolBalance - currentBalance
            );
        } else if (poolInfo.poolBalance < currentBalance) {
            // if new balance < current balance then transfer the difference back to the lender
            IERC20(poolInfo.loanToken).transfer(
                poolInfo.lender,
                currentBalance - poolInfo.poolBalance
            );
        }

        emit PoolBalanceUpdated(poolId, poolInfo.poolBalance);

        if (pools[poolId].lender == address(0)) {
            // if the pool doesn't exist then create it
            emit PoolCreated(poolId, poolInfo);
        } else {
            // if the pool does exist then update it
            emit PoolUpdated(poolId, poolInfo);
        }
        
        pools[poolId] = poolInfo;
    }

    /// @notice borrow a loan from a pool
    /// can be called by anyone
    /// you are allowed to open many borrows at once
    /// @param borrows a struct of all desired debt positions to be opened
    function borrow(Borrow[] calldata borrows) public {
        for (uint256 i = 0; i < borrows.length; i++) {
            bytes32 poolId = borrows[i].poolId;
            uint256 debt = borrows[i].debt;
            uint256 collateral = borrows[i].collateral;
            // get the pool info
            Pool memory pool = pools[poolId];
            // make sure the pool exists
            if (pool.lender == address(0)) revert PoolConfig();
            // validate the loan
            if (debt < pool.minLoanSize) revert LoanTooSmall();
            if (debt > pool.poolBalance) revert LoanTooLarge();
            if (collateral == 0) revert ZeroCollateral();
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
            emit PoolBalanceUpdated(poolId, pools[poolId].poolBalance);
            // transfer the loan tokens from the pool to the borrower
            IERC20(loan.loanToken).transfer(msg.sender, debt);
            // transfer the collateral tokens from the borrower to the contract
            IERC20(loan.collateralToken).transferFrom(
                msg.sender,
                address(this),
                collateral
            );
            loans.push(loan);
            emit Borrowed(
                msg.sender,
                pool.lender,
                loans.length - 1,
                debt,
                collateral,
                pool.interestRate,
                block.timestamp
            );
        }
    }

    /// @notice repay a loan
    /// can be called by anyone
    /// @param loanIds the ids of the loans to repay
    function repay(uint256[] calldata loanIds) public {
        for (uint256 i = 0; i < loanIds.length; i++) {
            uint256 loanId = loanIds[i];
            // get the loan info
            Loan memory loan = loans[loanId];
            // calculate the interest
            uint256 timeElapsed = block.timestamp - loan.startTimestamp;
            uint256 lenderInterest = ((loan.interestRate * loan.debt) / 10000) *
                (timeElapsed / 365 days);
            uint256 protocolInterest = ((fee * loan.debt) / 10000) *
                (timeElapsed / 365 days);

            bytes32 poolId = keccak256(
                abi.encode(loan.lender, loan.loanToken, loan.collateralToken)
            );

            // update the pool balance
            pools[poolId].poolBalance += loan.debt + lenderInterest;
            emit PoolBalanceUpdated(poolId, pools[poolId].poolBalance);

            // transfer the loan tokens from the borrower to the pool
            IERC20(loan.loanToken).transferFrom(
                msg.sender,
                address(this),
                loan.debt + lenderInterest
            );
            // transfer the protocol fee to the fee receiver
            IERC20(loan.loanToken).transferFrom(
                msg.sender,
                feeReceiver,
                protocolInterest
            );
            // transfer the collateral tokens from the contract to the borrower
            IERC20(loan.collateralToken).transfer(
                loan.borrower,
                loan.collateral
            );
            emit Repaid(
                msg.sender,
                loan.lender,
                loanId,
                loan.debt,
                loan.collateral,
                loan.interestRate,
                loan.startTimestamp
            );
            // delete the loan
            delete loans[loanId];
        }
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         REFINANCE                          */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice start a refinance auction
    /// can only be called by the lender
    /// @param loanIds the ids of the loans to refinance
    function startAuction(uint256[] calldata loanIds) public {
        for (uint256 i = 0; i < loanIds.length; i++) {
            uint256 loanId = loanIds[i];
            // get the loan info
            Loan memory loan = loans[loanId];
            // validate the loan
            if (msg.sender != loan.lender) revert Unauthorized();
            if (loan.auctionStartTimestamp != type(uint256).max)
                revert AuctionStarted();

            // set the auction start timestamp
            loans[loanId].auctionStartTimestamp = block.timestamp;
            emit AuctionStart(
                loan.borrower,
                loan.lender,
                loanId,
                loan.debt,
                loan.collateral,
                block.timestamp,
                loan.auctionLength
            );
        }
    }

    /// @notice buy a loan in a refinance auction
    /// can be called by anyone but you must have a pool with tokens
    /// @param loanId the id of the loan to refinance
    /// @param rate the interest rate the buyer is willing to accept
    function buyLoan(uint256 loanId, uint256 rate) public {
        // get the loan info
        Loan memory loan = loans[loanId];
        // validate the loan
        if (loan.auctionStartTimestamp == type(uint256).max)
            revert AuctionNotStarted();
        if (block.timestamp > loan.auctionStartTimestamp + loan.auctionLength)
            revert AuctionEnded();
        // calculate the current interest rate
        uint256 timeElapsed = block.timestamp - loan.auctionStartTimestamp;
        uint256 currentAuctionRate = (MAX_INTEREST_RATE * timeElapsed) /
            loan.auctionLength;
        // validate the rate
        if (rate > currentAuctionRate) revert RateTooHigh();
        // calculate the interest
        timeElapsed = block.timestamp - loan.startTimestamp;
        uint256 lenderInterest = ((loan.interestRate * loan.debt) / 10000) *
            (timeElapsed / 365 days);
        uint256 protocolInterest = ((fee * loan.debt) / 10000) *
            (timeElapsed / 365 days);

        // check if the buyer has a pool with tokens
        bytes32 poolId = keccak256(
            abi.encode(msg.sender, loan.loanToken, loan.collateralToken)
        );
        uint256 currentBalance = pools[poolId].poolBalance;
        // reject if the pool is not big enough
        if (currentBalance < loan.debt + lenderInterest + protocolInterest)
            revert PoolTooSmall();
        // if they do have a big enough pool then transfer from their pool
        pools[poolId].poolBalance -=
            loan.debt +
            lenderInterest +
            protocolInterest;
        emit PoolBalanceUpdated(poolId, pools[poolId].poolBalance);
        // now update the pool balance of the old lender
        bytes32 oldPoolId = keccak256(
            abi.encode(loan.lender, loan.loanToken, loan.collateralToken)
        );
        pools[oldPoolId].poolBalance += loan.debt + lenderInterest;
        emit PoolBalanceUpdated(oldPoolId, pools[oldPoolId].poolBalance);

        // transfer the protocol fee to the governance
        IERC20(loan.loanToken).transfer(feeReceiver, protocolInterest);

        emit Repaid(
            loan.borrower,
            loan.lender,
            loanId,
            loan.debt + lenderInterest + protocolInterest,
            loan.collateral,
            loan.interestRate,
            loan.startTimestamp
        );

        // update the loan with the new info
        loans[loanId].lender = msg.sender;
        loans[loanId].interestRate = rate;
        loans[loanId].startTimestamp = block.timestamp;
        loans[loanId].auctionStartTimestamp = type(uint256).max;
        loans[loanId].debt = loan.debt + lenderInterest + protocolInterest;

        emit Borrowed(
            loan.borrower,
            msg.sender,
            loanId,
            loans[loanId].debt,
            loans[loanId].collateral,
            rate,
            block.timestamp
        );
        emit LoanBought(loanId);
    }

    /// @notice sieze a loan after a failed refinance auction
    /// can be called by anyone
    /// @param loanIds the ids of the loans to sieze
    function seizeLoan(uint256[] calldata loanIds) public {
        for (uint256 i = 0; i < loanIds.length; i++) {
            uint256 loanId = loanIds[i];
            // get the loan info
            Loan memory loan = loans[loanId];
            // validate the loan
            if (loan.auctionStartTimestamp == type(uint256).max)
                revert AuctionNotStarted();
            if (
                block.timestamp <
                loan.auctionStartTimestamp + loan.auctionLength
            ) revert AuctionNotEnded();
            // calculate the fee
            uint256 govFee = (fee * loan.collateral) / 10000;
            // transfer the protocol fee to governance
            IERC20(loan.collateralToken).transfer(feeReceiver, govFee);
            // transfer the collateral tokens from the contract to the lender
            IERC20(loan.collateralToken).transfer(
                loan.lender,
                loan.collateral - govFee
            );
            emit LoanSiezed(
                loan.borrower,
                loan.lender,
                loanId,
                loan.collateral
            );
            // delete the loan
            delete loans[loanId];
        }
    }

    /// @notice refinance a loan to a new offer
    /// can only be called by the borrower
    /// @param refinances a struct of all desired debt positions to be refinanced
    function refinance(Refinance[] calldata refinances) public {
        for (uint256 i = 0; i < refinances.length; i++) {
            uint256 loanId = refinances[i].loanId;
            bytes32 poolId = refinances[i].poolId;
            bytes32 oldPoolId = keccak256(
                abi.encode(loans[loanId].lender, loans[loanId].loanToken, loans[loanId].collateralToken)
            );
            uint256 debt = refinances[i].debt;
            uint256 collateral = refinances[i].collateral;

            // get the loan info
            Loan memory loan = loans[loanId];
            // validate the loan
            if (msg.sender != loan.borrower) revert Unauthorized();

            // get the pool info
            Pool memory pool = pools[poolId];
            // validate the new loan
            if (pool.loanToken != loan.loanToken) revert TokenMismatch();
            if (pool.collateralToken != loan.collateralToken)
                revert TokenMismatch();
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

            // first lets deduct our tokens from the new pool
            pools[poolId].poolBalance -= debt;
            emit PoolBalanceUpdated(poolId, pools[poolId].poolBalance);

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
                IERC20(loan.loanToken).transfer(msg.sender, debt - debtToPay);
            }

            // update the old lenders pool
            pools[oldPoolId].poolBalance += loan.debt + lenderInterest;
            emit PoolBalanceUpdated(oldPoolId, pools[oldPoolId].poolBalance);
            // transfer the protocol fee to governance
            IERC20(loan.loanToken).transfer(feeReceiver, protocolInterest);

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

            emit Repaid(
                msg.sender,
                loan.lender,
                loanId,
                debt,
                collateral,
                loan.interestRate,
                loan.startTimestamp
            );

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
            emit Borrowed(
                msg.sender,
                pool.lender,
                loanId,
                debt,
                collateral,
                pool.interestRate,
                block.timestamp
            );
            emit Refinanced(loanId);
        }
    }
}
