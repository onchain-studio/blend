// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./utils/Errors.sol";
import "./utils/Structs.sol";

import {Ownable} from "./utils/Ownable.sol";
import {Lender} from "./Lender.sol";
import {IDataFeed} from "./interfaces/IDataFeed.sol";

import {ERC20} from "solady/src/tokens/ERC20.sol";
import {ISwapRouter} from "./interfaces/ISwapRouter.sol";

contract Pooler is ERC20 {
    string private _name;
    string private _symbol;

    Lender public lender;

    /// @notice the liquidation threshold of the pool
    /// @dev if the LTV of a loan is above this, it can be liquidated
    /// @dev this is a percentage multiplied by 10**18
    uint256 public liquidationThreshold = 9 * 10**17;

    IDataFeed public loanTokenOracle;
    IDataFeed public collateralTokenOracle;

    bytes32 public poolId;
    ERC20 public loanToken;
    ERC20 public collateralToken;

    uint256 public lastInterestUpdate;

    ISwapRouter public constant swapRouter = ISwapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564);

    constructor(
        string memory name_,
        string memory symbol_,
        address lender_,
        address loanToken_,
        address collateralToken_,
        address loanTokenOracle_,
        address collateralTokenOracle_
    ) {
        _name = name_;
        _symbol = symbol_;

        lender = Lender(lender_);
        loanToken = ERC20(loanToken_);
        collateralToken = ERC20(collateralToken_);
        loanTokenOracle = IDataFeed(loanTokenOracle_);
        collateralTokenOracle = IDataFeed(collateralTokenOracle_);

        (, int256 iloanTokenPrice, , , ) = loanTokenOracle.latestRoundData();
        (, int256 icollateralTokenPrice, , , ) = collateralTokenOracle.latestRoundData();

        uint256 loanTokenPrice = uint256(iloanTokenPrice);
        uint256 collateralTokenPrice = uint256(icollateralTokenPrice);

        uint256 newMaxLoanRatio = (loanTokenPrice * uint256(loanToken.decimals()) * 8**17) / (collateralTokenPrice * collateralToken.decimals());

        Pool memory p = Pool({
            lender: address(this),
            loanToken: loanToken_,
            collateralToken: collateralToken_,
            minLoanSize: 10*10**uint256(loanToken.decimals()),
            poolBalance: 0,
            maxLoanRatio: newMaxLoanRatio,
            auctionLength: 1 days,
            interestRate: 100,
            outstandingLoans: 0
        });

        lender.setPool(p);

        poolId = keccak256(abi.encode(p.lender, p.loanToken, p.collateralToken));

        loanToken.approve(lender_, type(uint256).max);
        collateralToken.approve(address(swapRouter), type(uint256).max);

        lastInterestUpdate = block.timestamp;
    }

    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    /// @notice update the interest rate of the pool
    /// @dev checks the pool utilization to do this
    function updateInterestRate() external {
        if (block.timestamp - lastInterestUpdate < 2 hours) revert();
        (,,,,uint256 totalPooled,,,uint256 interestRate,uint256 totalOutstanding) = lender.pools(poolId);
        // if utilization is > 75% we increase the interest rate by 0.5%
        if (totalPooled * 3 > totalOutstanding) {
            lender.updateInterestRate(poolId, interestRate - 50);
        } else {
            lender.updateInterestRate(poolId, interestRate + 50);
        }
    }

    /// @notice update the max loan to value based on the price of the tokens to 80% LTV
    function updateMaxLoanRatio() external {
        (, int256 iloanTokenPrice, , , ) = loanTokenOracle.latestRoundData();
        (, int256 icollateralTokenPrice, , , ) = collateralTokenOracle.latestRoundData();

        uint256 loanTokenPrice = uint256(iloanTokenPrice);
        uint256 collateralTokenPrice = uint256(icollateralTokenPrice);

        uint256 newMaxLoanRatio = (loanTokenPrice * uint256(loanToken.decimals()) * 8**17) / (collateralTokenPrice * uint256(collateralToken.decimals()));
        lender.updateMaxLoanRatio(poolId, newMaxLoanRatio);
    }

    /// @notice auction off loans where the LTV is > 90%
    /// @param loanIds the loan IDs to auction off
    function auctionLoans(uint256[] calldata loanIds) external {
        (, int256 iloanTokenPrice, , , ) = loanTokenOracle.latestRoundData();
        (, int256 icollateralTokenPrice, , , ) = collateralTokenOracle.latestRoundData();

        uint256 loanTokenPrice = uint256(iloanTokenPrice);
        uint256 collateralTokenPrice = uint256(icollateralTokenPrice);

        for (uint256 i = 0; i < loanIds.length; i++) {
            uint256 loanId = loanIds[i];
            uint256 debt = lender.getLoanDebt(loanId);
            uint256 debtUSD = debt * loanTokenPrice / 10**uint256(loanToken.decimals());
            (,,,,,uint256 collateral,,,,) = lender.loans(loanId);
            uint256 collateralUSD = collateral * collateralTokenPrice / 10**uint256(collateralToken.decimals());
            // if we are not above the liquidation threshold, revert
            if (debtUSD * 10**18 / collateralUSD < liquidationThreshold) revert();
        }
        lender.startAuction(loanIds);
    }

    function deposit(uint256 amount) external {
        if (collateralToken.balanceOf(address(this)) > 0) sellCollateralTokens();

        (,,,,uint256 totalPooled,,,,uint256 totalOutstanding) = lender.pools(poolId);
        uint256 totalLoanTokens = totalPooled + totalOutstanding;
        uint256 totalShares = totalSupply();

        if (totalShares == 0 || totalLoanTokens == 0) {
            _mint(msg.sender, amount);
        } else {
            uint256 what = amount * totalShares / totalLoanTokens;
            _mint(msg.sender, what);
        }

        loanToken.transferFrom(msg.sender, address(this), amount);
        lender.addToPool(poolId, amount);
    }

    function withdraw(uint256 amount) external {
        (,,,,uint256 totalPooled,,,,uint256 totalOutstanding) = lender.pools(poolId);
        uint256 totalLoanTokens = totalPooled + totalOutstanding;
        uint256 totalShares = totalSupply();

        uint256 what = amount * totalLoanTokens / totalShares;
        _burn(msg.sender, what);

        lender.removeFromPool(poolId, amount);
        loanToken.transfer(msg.sender, amount);
    }

    /// @notice swap loan tokens for collateral tokens from liquidations
    function sellCollateralTokens() public {
        uint256 amount = collateralToken.balanceOf(address(this));

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: address(collateralToken),
            tokenOut: address(loanToken),
            fee: 3000,
            recipient: address(this),
            deadline: block.timestamp,
            amountIn: amount,
            amountOutMinimum: 0,
            sqrtPriceLimitX96: 0
        });

        amount = swapRouter.exactInputSingle(params);
        lender.addToPool(poolId, amount);
    }
}
