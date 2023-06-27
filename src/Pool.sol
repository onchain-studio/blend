// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "./Errors.sol";
import "./Structs.sol";

import {Ownable} from "./Ownable.sol";
import {Lender} from "./Lender.sol";
import {IDataFeed} from "./IDataFeed.sol";

import {ERC20} from "solady/src/tokens/ERC20.sol";

contract Pool is ERC20 {
    string private immutable _name;
    string private immutable _symbol;

    Lender public immutable lender;

    /// @notice the liquidation threshold of the pool
    /// @dev if the LTV of a loan is above this, it can be liquidated
    /// @dev this is a percentage multiplied by 10**18
    uint256 private immutable _liquidationThreshold;

    IDataFeed public immutable loanTokenOracle;
    IDataFeed public immutable collateralTokenOracle;

    bytes32 public immutable poolId;
    ERC20 public immutable loanToken;
    ERC20 public immutable collateralToken;

    constructor(
        string memory name_,
        string memory symbol_,
        address calldata lender_,
        Pool memory p,
        address loanTokenOracle_,
        address collateralTokenOracle_,
        uint256 liquidationThreshold

    ) {
        _name = name_;
        _symbol = symbol_;

        lender = Lender(lender_);

        _liquidationThreshold = liquidationThreshold;
        loanTokenOracle = IDataFeed(loanTokenOracle_);
        collateralTokenOracle = IDataFeed(collateralTokenOracle_);

        lender.setPool(p);

        poolId = keccak256(abi.encode(p.lender, p.loanToken, p.collateralToken));
        loanToken = ERC20(p.loanToken);
        collateralToken = ERC20(p.collateralToken);

        loanToken.approve(lender, type(uint256).max);
    }

    function name() public view returns (string memory) {
        return _name;
    }

    function symbol() public view returns (string memory) {
        return _symbol;
    }

    /// @notice update the max loan to value based on the price of the tokens to 80% LTV
    function updateMaxLoanRatio() external {
        (, int256 loanTokenPrice, , , ) = loanTokenOracle.latestRoundData();
        (, int256 collateralTokenPrice, , , ) = collateralTokenOracle.latestRoundData();

        uint256 newMaxLoanRatio = (loanTokenPrice * loanToken.decimals() * 8**17) / (collateralTokenPrice * collateralToken.decimals());
        lender.updateMaxLoanRatio(poolId, newMaxLoanRatio);
    }

    /// @notice auction off loans where the LTV is > 90%
    /// @param loanIds the loan IDs to auction off
    function auctionLoans(uint256[] calldata loanIds) external {
        (, int256 loanTokenPrice, , , ) = loanTokenOracle.latestRoundData();
        (, int256 collateralTokenPrice, , , ) = collateralTokenOracle.latestRoundData();

        for (uint256 i = 0; i < loanIds.length; i++) {
            uint256 loanId = loanIds[i];
            uint256 debt = lender.getLoanDebt(loanId);
            uint256 debtUSD = debt * loanTokenPrice / 10**loanToken.decimals();
            (,,,,uint256 collateral,,,,) = lender.loans(loanId);
            uint256 collateralUSD = collateral * collateralTokenPrice / 10**collateralToken.decimals();
            // if we are not above the liquidation threshold, revert
            if (debtUSD * 10**18 / collateralUSD < _liquidationThreshold) revert();
        }
        lender.startAuction(loanIds);
    }

    function deposit(uint256 amount) external {
        loanToken.transferFrom(msg.sender, address(this), amount);
        lender.deposit(poolId, amount);
        _mint(msg.sender, amount);
    }
}
