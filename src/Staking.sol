// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IERC20} from "./interfaces/IERC20.sol";
import {Ownable} from "./utils/Ownable.sol";

interface FeeDistribution {
    function claim(address) external;
}

contract Staking is Ownable {

    uint256 public balance = 0;
    uint256 public index = 0;
    
    mapping(address => uint256) public supplyIndex;

    /// @notice mapping of user balances
    mapping(address => uint256) public balances;
    mapping(address => uint256) public claimable;
    
    IERC20 public immutable TKN;
    IERC20 public immutable WETH;

    constructor(address _token, address _weth) Ownable(msg.sender) {
        TKN = IERC20(_token);
        WETH = IERC20(_weth);
    }
    
    function deposit(uint _amount) external {
        TKN.transferFrom(msg.sender, address(this), _amount);
        updateFor(msg.sender);
        balances[msg.sender] += _amount;
    }

    function withdraw(uint _amount) external {
        updateFor(msg.sender);
        balances[msg.sender] -= _amount;
        TKN.transfer(msg.sender, _amount);
    }
    
    function claim() external {
        updateFor(msg.sender);
        WETH.transfer(msg.sender, claimable[msg.sender]);
        claimable[msg.sender] = 0;
        balance = WETH.balanceOf(address(this));
    }
    
    function update() public {
        uint256 totalSupply = TKN.balanceOf(address(this));
        if (totalSupply > 0) {
            uint256 _balance = WETH.balanceOf(address(this));
            if (_balance > balance) {
                uint256 _diff = _balance - balance;
                if (_diff > 0) {
                    uint256 _ratio = _diff * 1e18 / totalSupply;
                    if (_ratio > 0) {
                      index = index + _ratio;
                      balance = _balance;
                    }
                }
            }
        }
    }
    
    function updateFor(address recipient) public {
        update();
        uint256 _supplied = balances[recipient];
        if (_supplied > 0) {
            uint256 _supplyIndex = supplyIndex[recipient];
            supplyIndex[recipient] = index;
            uint256 _delta = index - _supplyIndex;
            if (_delta > 0) {
              uint256 _share = _supplied * _delta / 1e18;
              claimable[recipient] += _share;
            }
        } else {
            supplyIndex[recipient] = index;
        }
    }

}