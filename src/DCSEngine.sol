// SPDX-License-Identifier: MIT

// This is considered an Exogenous, Decentralized, Anchored (pegged), Crypto Collateralized low volitility coin

// Layout of Contract:
// version
// imports
// errors
// interfaces, libraries, contracts
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions


pragma solidity ^0.8.19;

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "../lib/chainlink-brownie-contracts/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";



/**
 * @title DSCEngine
 * @author Swarup Banik
 * 
 * The system is designed to be minimal as possible, and have the tokens maintain a 1 token == $1 peg.
 * This stablecoin has the properties:
 * - Exogenous Collateral
 * - Dollar pegged
 * - Algorithmically stable
 * 
 * It is similar to DAI had no governance, no fees, and was only backed by WETH and WBTC.
 * 
 * Our DSC system should always be overcollateralised. At no point, should the value of all collaterals <= the $ backed value of all the DSC.
 * 
 * @notice This contract is the core of the DSC(Decentralised Stable Coin) system. It handles all the logic for mining and redeeming DSC, as well as depositing and withdrawing collateral.
 * @notice This contract is very loosely based on the MakerDAO DSS (DAI) system.
 */


contract DSCEngine {

    ///////////////////////
    ////// Errors /////////
    //////////////////////
    error DSCEngine_NeedMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__TokenNotAllowed();
    error DSCEngine_TransferFailed();
    error DSCEngine_BreakHealthFactor(uint256 healthFactor);
    error DSCEngine_MintFailed();
    error DSCEngine_healthFactorOk();
    error DSCEngine_healthFactorNotImproved();

     ///////////////////////////////
    ////// State Variables /////////
    ////////////////////////////////

    DecentralizedStableCoin private immutable i_dsc;

    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10;
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% overcollateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10; // This means you get assets at a 10% discount when liquidating
    uint256 private constant FEED_PRECISION = 1e8;


    /// @dev Mapping of token address to price feed address
    mapping(address token => address priceFeed) private s_priceFeeds;
    /// @dev Amount of collateral deposited by user
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    /// @dev Amount of DSC minted by user
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted;
    
    address[] private s_collateralTokens;
    address weth;
    address wbtc;


 

    ///////////////////
    // Events
    ///////////////////
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(address indexed redeemedFrom, address indexed redeemedTo, address token, uint256 amount);

    ///////////////////////
    ////// Modifiers ////////
    //////////////////////
    modifier moreThanZero(uint256 amount) {
        if(amount == 0){
            revert DSCEngine_NeedMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if(s_priceFeeds[token] == address(0)){
            revert DSCEngine__TokenNotAllowed();
        }
        _;
    }

    constructor(
        address[] memory tokenAddresses,
        address[] memory priceFeedAddresses,
        address dscAddress
    ) {
        if(tokenAddresses.length != priceFeedAddresses.length){
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }

        //use price feeds, for e.g. ETH/USD, BTC/USD, MKR/USD etc
        for(uint256 i=0; i<tokenAddresses.length; i++){
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddresses[i]);
        }

        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    //////////////////////////////////
    ////// External Functions ////////
    //////////////////////////////////

    /**
     * 
     * @param tokenCollateralAddress The address of the token to deposit as collateral
     * @param amountCollateral The amount of collateral to deposit
     * @param amountDscToMint The amount of decentralized stablecoin to mint
     * @notice This function will deposit your collateral and mint DSC in one transaction.
     */
    function depositCollateralAndMintDsc(
        address tokenCollateralAddress, 
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress,amountCollateral);
        mintDsc(amountDscToMint);
    }

    // We should only allow certain kinds of collaterals in our system
    function depositCollateral(address _tokenCollateralAddress,  uint256 _amountCollateral) 
        public 
        moreThanZero(_amountCollateral) 
        isAllowedToken(_tokenCollateralAddress)
    {
        s_collateralDeposited[msg.sender][_tokenCollateralAddress] += _amountCollateral;
        emit CollateralDeposited(msg.sender, _tokenCollateralAddress, _amountCollateral);
        bool success = IERC20(_tokenCollateralAddress).transferFrom(msg.sender, address(this), _amountCollateral);
        if(!success){
            revert DSCEngine_TransferFailed();
        }
    }

    //when people are done with doing whatever with their stable coin DSC they can turn their stable coin DSC to whatever collateral they used.
    function redeemCollateralForDSC(
        address tokenCollateralAddress, 
        uint256 amountCollateral, 
        uint256 amountDscToBurn
    ) external {
        burnDSC(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
        // redeem collateral checks our health factor already
    }

    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral) 
        public 
        moreThanZero(amountCollateral)
    {
        _redeemCollateral(tokenCollateralAddress, amountCollateral, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }


    // Check if the collateral value > DSC amount. this will involve a lot of things like price feeds, values etc.
    function mintDsc(uint256 amountDscToMint)  public moreThanZero(amountDscToMint) {
        s_DSCMinted[msg.sender] += amountDscToMint;
        //if they minted too much (more than the threshold collateral balue then we will revert)
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if(!minted){
            revert DSCEngine_MintFailed();
        }
    }

    // id the person thinks that the value of collaterals is getting lower he can burn some existing tokens to minimize the supply
    function burnDSC(uint256 amountDsc) 
        public 
        moreThanZero(amountDsc)
    {
        _burnDSC(amountDsc, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender); // most prolly we dont need thsi line...
    }

    // lets say I put in $100 worth of ETH and minted $50 worth of DSC, thats completely okay, we are overcollateralized. 
    // but if they price of ETH drops down to $40 we are undercollateralized and now this user should be liquidated, 
    // this user should not be in our system any more. So we keep a threshold say $60 ETH, if the price drops down $60 then
    // the user should be kicked out of the system because the user is way to close to getting underCollateralized 
    // lets say $75 backing $50
    // Liquidator takes $75 backing and burns off the $50 DSC

    /**
     * 
     * @param collateral The ERC20 collateral address to liquidate from the user.
     * @param user Th euser who has broken the health factor. Their _healthFactor should be below MIN_HEALTH_FACTOR.
     * @param debtToCover The amount of DSC you want to burn to improve the health factor of the user.
     * @notice you can partially liquidate a user.
     * @notice you will get a liquidation bonus for taking the users funds.
     * @notice This function working assumess the protocol will be roughly 200% overcollateralized in order fro this to work.
     * @notice A known bug would be if the protocol were 100% or less collateralized, then we won't be able to incentivize the liquidators.
     * @notice for example, if the price of the collateral plummeted before anyone could be liquidated.
     */
    function liquidate(address collateral, address user, uint256 debtToCover) 
        external 
        moreThanZero(debtToCover) 
    {
        // need to check health factor of the user
        uint256 startingUserHealthFactor = _healthFactor(user);
        if(startingUserHealthFactor >= MIN_HEALTH_FACTOR){
            revert DSCEngine_healthFactorOk();
        }

        //we want to burn their DSC "debt"
        // and take their collateral
        // bad user: $140 ETH, $100 DSC
        // debtToCover = $100
        //$100 of DSC == ??? ETH?
        // 0.05 ETH
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
        //and give them a 10% bonus
        // so we are giving the liquidator $110 of WETH for 100 DSC
        // we should implement a feature to liquidate in the event the protocol is insolvent
        // and sweep extra amounts into a treasury

        //0.05 * 0.1 =0.055. Getting 0.055
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
        // the liquidator will redeem the collateral
        _redeemCollateral(collateral, totalCollateralToRedeem, user, msg.sender);
        //we need to burn the DSC now
        _burnDSC(debtToCover, user, msg.sender);

        uint256 endingHealthFactor = _healthFactor(user);
        if(endingHealthFactor <= startingUserHealthFactor){
            revert DSCEngine_healthFactorNotImproved();
        }

        // we should also revert if this process ruined the health factor of liquidator
        _revertIfHealthFactorIsBroken(msg.sender);
    }

     

    function getHealthFactor() external view {}



    //////////////////////////////////
    /// Private and Internal view Functions //
    //////////////////////////////////
    /**
     * Returns how close to liquidation a user is
     * If a user goes below 1, then they can get liquidated.
     */

    function _redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral, address from, address to) private {
        s_collateralDeposited[from][tokenCollateralAddress]-= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if(!success){
            revert DSCEngine_TransferFailed();
        }
    }

    /**
     * @dev Low-level internal function, do not call unless the function calling it is checking for health factors beign broken.
     */
    function _burnDSC(uint256 amountDscToBurn, address onBehalfOf, address dscFrom)
        private
    {
        s_DSCMinted[onBehalfOf] -= amountDscToBurn;
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);

        if(!success){
            revert DSCEngine_TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
        
    }

    function _getAccountInformation(address user) 
        private 
        view 
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd) 
    {
        totalDscMinted = s_DSCMinted[user];
        collateralValueInUsd = getAccountCollateralValue(user);  // returns the total value of all the collateral values teh user have.
    }

    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }
    

    // function _healthFactor(address user) private view returns(uint256){
    //     // total DSC minted
    //     // total collateral value
    //     (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);

    //     uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
    //     return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted; 
    // }

    function _calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        internal
        pure
        returns (uint256)
    {
        if (totalDscMinted == 0) return type(uint256).max;
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }


    // 1. Check health factor, if they have enough collateral or not.
    // 2. Revert if they don't.
    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if(userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine_BreakHealthFactor(userHealthFactor);
        }
    }
               
    //////////////////////////////////
    /// public and External view Functions //
    //////////////////////////////////

    function calculateHealthFactor(uint256 totalDscMinted, uint256 collateralValueInUsd)
        external
        pure
        returns (uint256)
    {
        return _calculateHealthFactor(totalDscMinted, collateralValueInUsd);
    }

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns(uint256) {
        // price of ETH 

        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        // ($10e18) / ($2000e8 * 1e10)
        //0.005 ETH 
        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }

    function getCollateralBalanceOfUser(address user, address token) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }

    function getAccountCollateralValue(address user) public view returns(uint256 totalCollateralValueInUsd){
        // loop through each collateral token, get the amount they have deposited, and map it to the price, to get the USD value
        
        for(uint256 i=0; i<s_collateralTokens.length;i++){
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd +=getUsdValue(token, amount);
        }

        return totalCollateralValueInUsd;
    }

    function getUsdValue(address token, uint256 amount) public view returns(uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (,int256 price,,,) = priceFeed.latestRoundData();
        // 1 ETH = $1000
        // The returned value from CL will be 1000*1e8
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION; //(1000 * 1e8 * (1e10)) * 1000 * 1e18;
    }

    function getAccountInformation(address user) 
        external
        view
        returns(uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        (totalDscMinted, collateralValueInUsd) = _getAccountInformation(user);
    }


    function getPrecision() external pure returns (uint256) {
        return PRECISION;
    }

    function getAdditionalFeedPrecision() external pure returns (uint256) {
        return ADDITIONAL_FEED_PRECISION;
    }

    function getLiquidationThreshold() external pure returns (uint256) {
        return LIQUIDATION_THRESHOLD;
    }

    function getLiquidationBonus() external pure returns (uint256) {
        return LIQUIDATION_BONUS;
    }

    function getLiquidationPrecision() external pure returns (uint256) {
        return LIQUIDATION_PRECISION;
    }

    function getMinHealthFactor() external pure returns (uint256) {
        return MIN_HEALTH_FACTOR;
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getDsc() external view returns (address) {
        return address(i_dsc);
    }

    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token];
    }

    function getHealthFactor(address user) external view returns (uint256) {
        return _healthFactor(user);
    }
}