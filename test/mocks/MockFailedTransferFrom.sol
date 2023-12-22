// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.18;

import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract MockFailedTransferFrom is ERC20Burnable, Ownable {
    error DecentralizedStableCoin__MustBeMoreThanZero();
    error DecentralizedStableCoin__BurnAmountExceedsBalance();

    constructor() ERC20("DecentralizedStableCoin", "DSC") Ownable(msg.sender) {}

    function burn(uint256 _amount) public override onlyOwner {
        uint256 balance = balanceOf(msg.sender);
        if (_amount <= 0) revert DecentralizedStableCoin__MustBeMoreThanZero();
        if (balance < _amount) revert DecentralizedStableCoin__BurnAmountExceedsBalance();
        super.burn(_amount);
    }

    function mint(address _account, uint256 _amount) public {
        _mint(_account, _amount);
    }

    function transferFrom(address, /*_from*/ address, /*_to*/ uint256 /*_amount*/ )
        public
        pure
        override
        returns (bool)
    {
        return false;
    }
}
