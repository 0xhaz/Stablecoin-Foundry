// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title Invariant Test
 * @notice The total supply of DSC should be less than the total value of collateral
 * @notice Getter view functions should never revert
 */

contract InvariantTest is StdInvariant, Test {
    DSCEngine dsce;
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    HelperConfig helperConfig;
    address weth;
    address wbtc;

    function setUp() external {
        deployer = new DeployDSC();
        (dsc, dsce, helperConfig) = deployer.run();
        (,, weth, wbtc,) = helperConfig.activeNetworkConfig();
        targetContract(address(dsce));
    }

    // function invariant_protocol_Must_Have_More_Value_Than_Total_Supply() public view {
    //     // Get the value of all collateral in the protocol
    //     // compare it too all the debt (dsc)
    //     uint256 totalSupply = dsc.totalSupply();
    //     uint256 totalWethDeposited = IERC20(weth).balanceOf(address(dsce));
    //     uint256 totalWbtcDeposited = IERC20(wbtc).balanceOf(address(dsce));

    //     uint256 wethValue = dsce.getUsdValue(weth, totalWethDeposited);
    //     uint256 wbtcValue = dsce.getUsdValue(wbtc, totalWbtcDeposited);

    //     console.log("WETH Value: %s", wethValue);
    //     console.log("WBTC Value: %s", wbtcValue);
    //     console.log("Total Supply: %s", totalSupply);

    //     assert(wethValue + wbtcValue >= totalSupply);
    // }
}
