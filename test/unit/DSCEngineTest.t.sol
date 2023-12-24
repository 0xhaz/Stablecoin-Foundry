// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "@openzeppelin/contracts/mocks/token/ERC20Mock.sol";
import {MockFailedTransferFrom} from "../mocks/MockFailedTransferFrom.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";
import {MockFailedMintDSC} from "../mocks/MockFailedMintDSC.sol";
import {MockFailedTransfer} from "../mocks/MockFailedTransfer.sol";
import {MockMoreDebtDSC} from "../mocks/MockMoreDebtDSC.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dsce;
    HelperConfig config;

    address ethUsdPriceFeed;
    address wbtcUsdPriceFeed;
    address weth;
    address public USER = makeAddr("user");
    uint256 public AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;
    uint256 public constant MIN_HEALTH_FACTOR = 1e18;
    uint256 public constant LIQUIDATION_THRESHOLD = 50;
    uint256 public MINT_AMOUNT = 100 ether;

    address public LIQUIDATOR = makeAddr("liquidator");
    uint256 public COLLATERAL_TO_COVER = 20 ether;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dsce, config) = deployer.run();
        (ethUsdPriceFeed, wbtcUsdPriceFeed, weth,,) = config.activeNetworkConfig();

        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
    }

    //***** Constructor Test *****//
    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function test_Reverts_If_Token_Length_Doesnt_Match_Price_Feeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(wbtcUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    //***** Price Test *****//

    function test_Get_Usd_Value() public {
        uint256 ethAmount = 15e18;
        // 15e18 * 2000e8 / 1e18 = 30_000e8
        uint256 expectedUsd = 30_000e18;
        uint256 actualUsd = dsce.getUsdValue(weth, ethAmount);
        assertEq(expectedUsd, actualUsd);
    }

    function test_Get_Token_Amount_From_Usd() public {
        uint256 usdAmount = 100 ether;
        uint256 expectedWeth = 0.05 ether;
        uint256 actualWeth = dsce.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(expectedWeth, actualWeth);
    }

    //***** Deposit Collateral Test *****//

    // This test needs it's own setup
    function test_Reverts_If_TransferFrom_Fails() public {
        address owner = msg.sender;
        vm.prank(owner);
        MockFailedTransferFrom mockDsc = new MockFailedTransferFrom();
        tokenAddresses = [address(mockDsc)];
        priceFeedAddresses = [ethUsdPriceFeed];
        vm.prank(owner);
        DSCEngine mockDsce = new DSCEngine(tokenAddresses, priceFeedAddresses, address(mockDsc));
        mockDsc.mint(USER, AMOUNT_COLLATERAL);

        vm.prank(owner);
        mockDsc.transferOwnership(address(mockDsc));
        // Arrange
        vm.startPrank(USER);
        ERC20Mock(address(mockDsc)).approve(address(mockDsc), AMOUNT_COLLATERAL);
        // Act
        vm.expectRevert(DSCEngine.DSCEngine__TransferFailed.selector);
        mockDsce.depositCollateral(address(mockDsc), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    function test_Reverts_If_Collateral_Zero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    function test_Reverts_With_Unapproved_Collateral() public {
        ERC20Mock ranToken = new ERC20Mock();
        vm.startPrank(USER);

        vm.expectRevert(DSCEngine.DSCEngine__NotAllowedToken.selector);
        dsce.depositCollateral(address(ranToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function test_Can_Deposit_Collateral_Without_Minting() public {
        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, 0);
    }

    function test_Can_Deposit_Collateral_And_Get_Account_Info() public depositedCollateral {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);
        console.log("collateralValueInUsd: %s", collateralValueInUsd);

        uint256 expectedTotalDscMinted = 0;
        uint256 expectedDepositAmount = dsce.getUsdValue(weth, AMOUNT_COLLATERAL);
        console.log("expectedDepositAmount: %s", expectedDepositAmount);

        assertEq(totalDscMinted, expectedTotalDscMinted);
        // 10000000000000000000 = 10e18
        // 40000000000000000000000000 = 40_000e18
        assertEq(collateralValueInUsd, expectedDepositAmount);
    }

    function test_Get_Account_Collateral_Value() public depositedCollateral {
        uint256 collateralValueInUsd = dsce.getAccountCollateralValue(USER);
        uint256 expectedDepositAmount = dsce.getUsdValue(weth, AMOUNT_COLLATERAL);
        assertEq(collateralValueInUsd, expectedDepositAmount);
    }

    //***** Deposit Collateral & Mint Test *****//

    modifier depositedCollateralAndMintDsc() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, MINT_AMOUNT);
        vm.stopPrank();
        _;
    }

    function test_Can_Mint_With_Deposit_Collateral() public depositedCollateralAndMintDsc {
        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, MINT_AMOUNT);
    }

    function test_Reverts_If_Minted_Dsc_Breaks_Health_Factor() public {
        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        // 10e18 * 2000e8 / 1e18 = 20_000e18
        MINT_AMOUNT = (AMOUNT_COLLATERAL * (uint256(price) * dsce.getAdditionalFeedPrecision())) / dsce.getPrecision();
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        uint256 expectedHealthFactor =
            dsce.calculateHealthFactor(MINT_AMOUNT, dsce.getUsdValue(weth, AMOUNT_COLLATERAL));
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, MINT_AMOUNT);
        vm.stopPrank();
    }

    // ***** MintDSC Test *****//

    function test_Reverts_If_Mint_Fails() public {
        // Arrange
        MockFailedMintDSC mockDsc = new MockFailedMintDSC();
        tokenAddresses = [weth];
        priceFeedAddresses = [ethUsdPriceFeed];
        address owner = msg.sender;
        vm.prank(owner);
        DSCEngine mockDsce = new DSCEngine(tokenAddresses, priceFeedAddresses, address(mockDsc));
        mockDsc.transferOwnership(address(mockDsce));

        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(mockDsce), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__MintFailed.selector);
        mockDsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, MINT_AMOUNT);
        vm.stopPrank();
    }

    function test_Reverts_If_Mint_Amount_Is_Zero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, MINT_AMOUNT);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.mintDsc(0);
        vm.stopPrank();
    }

    function test_Reverts_If_Mint_Amount_Breaks_Health_Factor() public depositedCollateral {
        (, int256 price,,,) = MockV3Aggregator(ethUsdPriceFeed).latestRoundData();
        MINT_AMOUNT = (AMOUNT_COLLATERAL * (uint256(price) * dsce.getAdditionalFeedPrecision())) / dsce.getPrecision();

        vm.startPrank(USER);
        uint256 expectedHealthFactor =
            dsce.calculateHealthFactor(MINT_AMOUNT, dsce.getUsdValue(weth, AMOUNT_COLLATERAL));
        vm.expectRevert(abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedHealthFactor));
        dsce.mintDsc(MINT_AMOUNT);
        vm.stopPrank();
    }

    function test_Can_Mint_Dsc() public depositedCollateral {
        vm.prank(USER);
        dsce.mintDsc(MINT_AMOUNT);

        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, MINT_AMOUNT);
    }

    //***** Burn DSC Test *****//

    function test_Reverts_If_Burn_Amount_Is_Zero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, MINT_AMOUNT);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.burnDsc(0);
        vm.stopPrank();
    }

    function test_Cant_Burn_More_Than_User_Has() public {
        vm.prank(USER);
        vm.expectRevert();
        dsce.burnDsc(1);
    }

    function test_Can_Burn_Dsc() public depositedCollateralAndMintDsc {
        vm.startPrank(USER);
        dsc.approve(address(dsce), MINT_AMOUNT);
        dsce.burnDsc(MINT_AMOUNT);
        vm.stopPrank();

        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, 0);
    }

    //***** Redeem DSC Test *****//

    function test_Must_Redeem_More_Than_Zero() public depositedCollateralAndMintDsc {
        vm.startPrank(USER);
        dsc.approve(address(dsce), MINT_AMOUNT);
        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.redeemCollateralForDsc(weth, 0, MINT_AMOUNT);
        vm.stopPrank();
    }

    function test_Can_Redeem_Deposited_Collateral() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, MINT_AMOUNT);
        dsc.approve(address(dsce), MINT_AMOUNT);
        dsce.redeemCollateralForDsc(weth, AMOUNT_COLLATERAL, MINT_AMOUNT);
        vm.stopPrank();

        uint256 userBalance = dsc.balanceOf(USER);
        assertEq(userBalance, 0);
    }

    //***** HealthFactor Test *****//

    function test_Properly_Reports_Health_Factor() public depositedCollateralAndMintDsc {
        uint256 expectedHealthFactor = 100 ether;
        uint256 healthFactor = dsce.getHealthFactor(USER);
        // $100 minted with $20,000 collateral at 50% liquidation threshold
        // means that we must have $200 in collateral to be at 100% health factor
        // 20_000 * 0.5 = 10_000
        // 10_000 / 100 = 100 health factor
        assertEq(healthFactor, expectedHealthFactor);
    }

    function test_Health_Factor_Can_Go_Below_One() public depositedCollateralAndMintDsc {
        int256 ethUsdUpdatedPrice = 18e8;
        // Remember, we need $200 at all times if we have $100 of debt
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);

        uint256 userHealthFactor = dsce.getHealthFactor(USER);
        // 180 * 50 (liquidation threshold) / 100 (liquidation precision) / 100 (precision) = 90 / 100 (totalDscMinted) = 0.9
        assert(userHealthFactor == 0.9 ether);
    }

    //***** Liquidation Test *****//

    modifier liquidated() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, MINT_AMOUNT);
        vm.stopPrank();
        int256 ethUsdUpdatedPrice = 18e8;

        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);
        uint256 userHealthFactor = dsce.getHealthFactor(USER);

        ERC20Mock(weth).mint(LIQUIDATOR, COLLATERAL_TO_COVER);

        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(dsce), COLLATERAL_TO_COVER);
        dsce.depositCollateralAndMintDsc(weth, COLLATERAL_TO_COVER, MINT_AMOUNT);
        dsc.approve(address(dsce), MINT_AMOUNT);
        dsce.liquidate(weth, USER, MINT_AMOUNT);
        vm.stopPrank();
        _;
    }

    function test_Must_Improve_Health_Factor_On_Liquidation() public {
        MockMoreDebtDSC mockDsc = new MockMoreDebtDSC(ethUsdPriceFeed);
        tokenAddresses = [weth];
        priceFeedAddresses = [ethUsdPriceFeed];
        address owner = msg.sender;
        vm.prank(owner);
        DSCEngine mockDsce = new DSCEngine(tokenAddresses, priceFeedAddresses, address(mockDsc));
        mockDsc.transferOwnership(address(mockDsce));

        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(mockDsce), AMOUNT_COLLATERAL);
        mockDsce.depositCollateralAndMintDsc(weth, AMOUNT_COLLATERAL, MINT_AMOUNT);
        vm.stopPrank();

        COLLATERAL_TO_COVER = 1 ether;
        ERC20Mock(weth).mint(LIQUIDATOR, COLLATERAL_TO_COVER);

        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(mockDsce), COLLATERAL_TO_COVER);
        uint256 debtToCover = 10 ether;
        mockDsce.depositCollateralAndMintDsc(weth, COLLATERAL_TO_COVER, MINT_AMOUNT);
        mockDsc.approve(address(mockDsce), debtToCover);

        int256 ethUsdUpdatedPrice = 18e8;
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);

        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorNotImproved.selector);
        mockDsce.liquidate(weth, USER, debtToCover);

        vm.stopPrank();
    }

    function test_Cant_Liquidate_Good_Health_Factor() public depositedCollateralAndMintDsc {
        ERC20Mock(weth).mint(LIQUIDATOR, COLLATERAL_TO_COVER);

        vm.startPrank(LIQUIDATOR);
        ERC20Mock(weth).approve(address(dsce), COLLATERAL_TO_COVER);
        dsce.depositCollateralAndMintDsc(weth, COLLATERAL_TO_COVER, MINT_AMOUNT);
        dsc.approve(address(dsce), MINT_AMOUNT);

        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOK.selector);
        dsce.liquidate(weth, USER, MINT_AMOUNT);
        vm.stopPrank();
    }

    function test_Liquidate_Payout_Is_Correct() public liquidated {
        uint256 liquidatorWethBalance = ERC20Mock(weth).balanceOf(LIQUIDATOR);
        uint256 expectedWeth = dsce.getTokenAmountFromUsd(weth, MINT_AMOUNT)
            + (dsce.getTokenAmountFromUsd(weth, MINT_AMOUNT) / dsce.getLiquidationBonus());
        uint256 hardCodedExpected = 6111111111111111110;
        assertEq(liquidatorWethBalance, hardCodedExpected);
        assertEq(liquidatorWethBalance, expectedWeth);
    }

    function test_User_Still_Has_Some_Eth_After_Liquidation() public liquidated {
        // Get how much WETH the user lost
        uint256 amountLiquidated = dsce.getTokenAmountFromUsd(weth, MINT_AMOUNT)
            + (dsce.getTokenAmountFromUsd(weth, MINT_AMOUNT) / dsce.getLiquidationBonus());

        uint256 usdAmountLiquidated = dsce.getUsdValue(weth, amountLiquidated);
        uint256 expectedUserCollateralValueInUsd = dsce.getUsdValue(weth, AMOUNT_COLLATERAL) - (usdAmountLiquidated);

        (, uint256 userCollateralValueInUsd) = dsce.getAccountInformation(USER);
        uint256 hardCodedExpectedValue = 70000000000000000020;
        assertEq(userCollateralValueInUsd, expectedUserCollateralValueInUsd);
        assertEq(userCollateralValueInUsd, hardCodedExpectedValue);
    }

    function test_Liquidator_Takes_On_Users_Debt() public liquidated {
        (uint256 liquidatorDscMinted,) = dsce.getAccountInformation(LIQUIDATOR);
        assertEq(liquidatorDscMinted, MINT_AMOUNT);
    }

    function test_User_Has_No_More_Debt() public liquidated {
        (uint256 userDscMinted,) = dsce.getAccountInformation(USER);
        assertEq(userDscMinted, 0);
    }

    function test_User_Has_No_More_Collateral() public liquidated {
        (, uint256 userCollateralValueInUsd) = dsce.getAccountInformation(USER);
        assertEq(userCollateralValueInUsd, 70000000000000000020);
    }

    //***** View & Pure Function Test *****//
    function test_Get_Collateral_Token_Price_Feed() public {
        address priceFeed = dsce.getCollateralTokenPriceFeed(weth);
        assertEq(priceFeed, ethUsdPriceFeed);
    }

    function test_Get_Collateral_Tokens() public {
        address[] memory collateralTokens = dsce.getCollateralTokens();
        assertEq(collateralTokens[0], weth);
    }

    function test_Get_Min_Health_Factor() public {
        uint256 minHealthFactor = dsce.getMinHealthFactor();
        assertEq(minHealthFactor, MIN_HEALTH_FACTOR);
    }

    function test_Get_Liquidation_Threshold() public {
        uint256 liquidationThreshold = dsce.getLiquidationThreshold();
        assertEq(liquidationThreshold, LIQUIDATION_THRESHOLD);
    }

    function test_Get_Account_Collateral_Value_From_Information() public depositedCollateral {
        (, uint256 collateralValue) = dsce.getAccountInformation(USER);
        uint256 expectedCollateralValue = dsce.getUsdValue(weth, AMOUNT_COLLATERAL);
        console.log("collateralValue: %s", collateralValue);
        console.log("expectedCollateralValue: %s", expectedCollateralValue);
        assertEq(collateralValue, expectedCollateralValue);
    }

    function test_Get_Collateral_Balance_Of_User() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        uint256 balance = dsce.getCollateralBalanceOfUser(USER, weth);
        assertEq(balance, AMOUNT_COLLATERAL);
    }

    function test_Get_Dsc() public {
        address dscAddress = dsce.getDscAddress();
        assertEq(dscAddress, address(dsc));
    }

    function test_Liquidation_Precision() public {
        uint256 expectedPrecision = 100;
        uint256 precision = dsce.getLiquidationPrecision();
        assertEq(precision, expectedPrecision);
    }

    function test_Get_Additional_Feed_Precision() public {
        uint256 expectedPrecision = 1e10;
        uint256 precision = dsce.getAdditionalFeedPrecision();
        assertEq(precision, expectedPrecision);
    }

    function test_Get_Precision() public {
        uint256 expectedPrecision = 1e18;
        uint256 precision = dsce.getPrecision();
        assertEq(precision, expectedPrecision);
    }

    function test_Get_Liquidation_Bonus() public {
        uint256 expectedBonus = 10;
        uint256 bonus = dsce.getLiquidationBonus();
        assertEq(bonus, expectedBonus);
    }
}
