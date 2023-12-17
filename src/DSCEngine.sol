// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.18;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title DSCEngine
 * @author 0xhaz
 * @notice The system is designed to be as minimal as possible, and have the tokens maintain at 1:1 with the USD.
 * @notice This stablecoin has the properties:
 * - Exogenous Collateral (ETH & BTC)
 * - Dollar Pegged
 * - Algorithmic Stable
 * It is similar to DAI if DAI had no governance, no fees, and was only backed by WETH and WBTC.
 * Our DSC system should always be "overcollateralized". At no point, should the value of all collateral <= the $ backed value of all DSC.
 * @notice This contract is the core of the DSC System. It handles all the loginc for mining and redeeming DSC, as well as
 * depositing and withdrawing collateral.
 * @notice This contract is VERY loosely based on the MakerDAO system, but is not a direct copy.
 */

contract DSCEngine is ReentrancyGuard {
    /**
     * Error  *****
     */

    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();

    /**
     * State Variables  *****
     */
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% overcollateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTORY = 1; // 100% overcollateralized

    DecentralizedStableCoin private immutable i_dsc;
    address[] private s_collateralTokens;

    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted;

    /**
     * Events  *****
     */
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(address indexed user, address indexed token, uint256 indexed amount);

    /**
     * Modifiers  *****
     */
    modifier moreThanZero(uint256 _amount) {
        if (_amount == 0) revert DSCEngine__NeedsMoreThanZero();
        _;
    }

    modifier isAllowedToken(address _token) {
        if (s_priceFeeds[_token] == address(0)) revert DSCEngine__NotAllowedToken();
        _;
    }

    /**
     * Functions  *****
     */
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddress, address dscAddress) {
        if (tokenAddresses.length != priceFeedAddress.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddress[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    /**
     * External Functions *****
     */

    /**
     * @notice This function will deposit your collateral and mint DSC in one transaction
     * @param tokenColleteralAddress  The address of the collateral token to deposit
     * @param amountCollateral  The amount of collateral to deposit
     * @param amountDscToMint  The amount of DSC to mint
     */
    function depositCollateralAndMintDsc(
        address tokenColleteralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenColleteralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /**
     * @notice Follows CEI pattern (Check-Effect-Interaction)
     * @param tokenCollateralAddress  The address of the collateral token to deposit
     * @param amountCollateral  The amount of collateral to deposit
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) revert DSCEngine__TransferFailed();
    }

    /**
     * @notice This function will redeem your collateral and burn DSC in one transaction
     * @param tokenCollateralAddress  The address of the collateral token to redeem
     * @param amountCollateral  The amount of collateral to redeem
     * @param amountDscToBurn  The amount of DSC to burn
     */
    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn)
        external
    {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
    }

    /**
     * @notice In order to redeem collateral, health factor must be above 1
     * @notice Follows CEI pattern (Check-Effect-Interaction)
     * @param tokenCollateralAddress  The address of the collateral token to redeem
     * @param amountCollateral  The amount of collateral to redeem
     */
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(msg.sender, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transfer(msg.sender, amountCollateral);
        if (!success) revert DSCEngine__TransferFailed();
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @notice Follows CEI pattern (Check-Effect-Interaction)
     * @param amountDscToMint The amount of DSC to mint
     * @notice They must have more collateral value than the amount of DSC they are minting
     */
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDscToMint;
        // if they minted too much DSC, revert
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) revert DSCEngine__MintFailed();
    }

    function burnDsc(uint256 amount) public moreThanZero(amount) {
        s_DSCMinted[msg.sender] -= amount;
        bool success = i_dsc.transferFrom(msg.sender, address(this), amount);
        if (!success) revert DSCEngine__TransferFailed();
        i_dsc.burn(amount);
        _revertIfHealthFactorIsBroken(msg.sender); // Not sure if this is needed
    }

    function liquidate() external {}

    function getHealthFactor() external {}

    /**
     * Private & Internal View Functions *****
     */

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        totalDscMinted = s_DSCMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);
    }

    /**
     * @notice Returns how close to liquidation a user is
     * @notice If a user goes below a health factor of 1, they are liquidated
     * @param user The address of the user to check the health factor of
     */
    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        // 1000 ETH * 50 = 50,000 / 1000 = 500
        // $150 ETH / 100 DSC = $1.5
        // 150 * 50 = 7500 / 100 = (75 / 100) < 1
        // 1000 ETH / 100 DSC
        // 1000 * 50 = 50,000 / 100 = (500 / 100) > 1
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    /**
     * @notice Check health factor (do they have enough collateral to back their DSC)
     * @notice revert if health factor is below 1
     * @param user The address of the user to check the health factor of
     */
    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTORY) revert DSCEngine__BreaksHealthFactor(userHealthFactor);
    }

    /**
     * Public & External View Functions *****
     */
    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        // loop through each collateral token, get the amount they have deposited and map it to the price feed
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        // 1 ETH = $1000
        // The returned value from CL will be 1000 * 1e8
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION; // 1e10 * 1e18 / 1e18 = 1e10
    }
}
