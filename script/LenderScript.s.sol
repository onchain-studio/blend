// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Script.sol";
import "../src/Lender.sol";
import "../src/Staking.sol";
import "../src/Beedle.sol";

import {WETH} from "solady/src/tokens/WETH.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {VestingWallet} from "openzeppelin-contracts/contracts/finance/VestingWallet.sol";

contract TERC20 is ERC20 {

    uint8 private _decimals;
    constructor(string memory name_, string memory symbol_, uint8 decimals_)
        ERC20(name_, symbol_)
    {
        _decimals = decimals_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }
}

contract TERC20Factory {
    function create(string memory name, string memory symbol, uint8 decimals)
        external
        returns (address)
    {
        return address(new TERC20(name, symbol, decimals));
    }
}

contract LenderScript is Script {
    function run() public {
        uint256 deployer = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployer);
        new Lender();
        address beedle = address(new Beedle());
        address weth = address(new WETH());
        address staking = address(new Staking(beedle, weth));
        address testERC20Factory = address(new TERC20Factory());

        vm.stopBroadcast();
    }
}
