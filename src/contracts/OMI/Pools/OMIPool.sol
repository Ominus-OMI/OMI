// SPDX-License-Identifier: MIT
pragma solidity ^0.6.10;
pragma experimental ABIEncoderV2;

import "../../OMI/OMI.sol";
import "../../Governance/AccessControl.sol";
import "../../Math/SafeMath.sol";
import "./OMIPoolLibrary.sol";
import "../../OMS/OMS.sol";
import "../../ERC20/ERC20.sol";
import "../../Oracle/UniswapPairOracle.sol";

contract OMIPool is AccessControl {
    using SafeMath for uint256;

    /* ========== STATE VARIABLES ========== */

    ERC20 private collateral_token;
    address private collateral_address;
    address private owner_address;

    address private OMI_contract_address;
    address private OMS_contract_address;
    address private timelock_address;
    OMIShares private OMS;
    OMIStablecoin private OMI;

    UniswapPairOracle private collatEthOracle;
    address public collat_eth_oracle_address;
    address private weth_address;

    uint256 public minting_fee;
    uint256 public redemption_fee;
    uint256 public buyback_fee;
    uint256 public recollat_fee;

    mapping (address => uint256) public redeemOMSBalances;
    mapping (address => uint256) public redeemCollateralBalances;
    uint256 public unclaimedPoolCollateral;
    uint256 public unclaimedPoolOMS;
    mapping (address => uint256) public lastRedeemed;

    uint256 public pool_ceiling = 0;
    uint256 public pausedPrice = 0;
    uint256 public bonus_rate = 7500;
    uint256 public redemption_delay = 1;
    uint256 private constant PRICE_PRECISION = 1e6;
    uint256 private constant COLLATERAL_RATIO_PRECISION = 1e6;
    uint256 private constant COLLATERAL_RATIO_MAX = 1e6;

    uint256 private immutable missing_decimals;
    

    bytes32 private constant RECOLLATERALIZE_PAUSER = keccak256("RECOLLATERALIZE_PAUSER");
    bytes32 private constant BUYBACK_PAUSER = keccak256("BUYBACK_PAUSER");
    bytes32 private constant MINT_PAUSER = keccak256("MINT_PAUSER");
    bytes32 private constant COLLATERAL_PRICE_PAUSER = keccak256("COLLATERAL_PRICE_PAUSER");
    bytes32 private constant REDEEM_PAUSER = keccak256("REDEEM_PAUSER");
    
    // AccessControl state variables
    bool public recollateralizePaused = false;
    bool public collateralPricePaused = false;
    bool public mintPaused = false;
    bool public redeemPaused = false;
    bool public buyBackPaused = false;

    /* ========== MODIFIERS ========== */

    modifier onlyByOwnerOrGovernance() {
        require(msg.sender == timelock_address || msg.sender == owner_address, "You are not the owner or the governance timelock");
        _;
    }

    modifier notRedeemPaused() {
        require(redeemPaused == false, "Redeeming is paused");
        _;
    }

    modifier notMintPaused() {
        require(mintPaused == false, "Minting is paused");
        _;
    }
 
    /* ========== CONSTRUCTOR ========== */
    
    constructor(
        address _OMI_contract_address,
        address _OMS_contract_address,
        address _collateral_address,
        address _creator_address,
        address _timelock_address,
        uint256 _pool_ceiling
    ) public {
        OMI = OMIStablecoin(_OMI_contract_address);
        OMS = OMIShares(_OMS_contract_address);
        OMI_contract_address = _OMI_contract_address;
        OMS_contract_address = _OMS_contract_address;
        collateral_address = _collateral_address;
        timelock_address = _timelock_address;
        owner_address = _creator_address;
        collateral_token = ERC20(_collateral_address);
        pool_ceiling = _pool_ceiling;
        missing_decimals = uint(18).sub(collateral_token.decimals());

        _setupRole(DEFAULT_ADMIN_ROLE, _msgSender());
        grantRole(MINT_PAUSER, timelock_address);
        grantRole(REDEEM_PAUSER, timelock_address);
        grantRole(RECOLLATERALIZE_PAUSER, timelock_address);
        grantRole(BUYBACK_PAUSER, timelock_address);
        grantRole(COLLATERAL_PRICE_PAUSER, timelock_address);
    }

    /* ========== VIEWS ========== */

    function collatDollarBalance() public view returns (uint256) {
        if(collateralPricePaused == true){
            return (collateral_token.balanceOf(address(this)).sub(unclaimedPoolCollateral)).mul(10 ** missing_decimals).mul(pausedPrice).div(PRICE_PRECISION);
        } else {
            uint256 eth_usd_price = OMI.eth_usd_price();
            uint256 eth_collat_price = collatEthOracle.consult(weth_address, (PRICE_PRECISION * (10 ** missing_decimals)));

            uint256 collat_usd_price = eth_usd_price.mul(PRICE_PRECISION).div(eth_collat_price);
            return (collateral_token.balanceOf(address(this)).sub(unclaimedPoolCollateral)).mul(10 ** missing_decimals).mul(collat_usd_price).div(PRICE_PRECISION); 
        }
    }

    function availableExcessCollatDV() public view returns (uint256) {
        uint256 total_supply = OMI.totalSupply();
        uint256 global_collateral_ratio = OMI.global_collateral_ratio();
        uint256 global_collat_value = OMI.globalCollateralValue();

        if (global_collateral_ratio > COLLATERAL_RATIO_PRECISION) global_collateral_ratio = COLLATERAL_RATIO_PRECISION; 
        uint256 required_collat_dollar_value_d18 = (total_supply.mul(global_collateral_ratio)).div(COLLATERAL_RATIO_PRECISION); 
        if (global_collat_value > required_collat_dollar_value_d18) return global_collat_value.sub(required_collat_dollar_value_d18);
        else return 0;
    }

    /* ========== PUBLIC FUNCTIONS ========== */
    
    function getCollateralPrice() public view returns (uint256) {
        if(collateralPricePaused == true){
            return pausedPrice;
        } else {
            uint256 eth_usd_price = OMI.eth_usd_price();
            return eth_usd_price.mul(PRICE_PRECISION).div(collatEthOracle.consult(weth_address, PRICE_PRECISION * (10 ** missing_decimals)));
        }
    }

    function setCollatETHOracle(address _collateral_weth_oracle_address, address _weth_address) external onlyByOwnerOrGovernance {
        collat_eth_oracle_address = _collateral_weth_oracle_address;
        collatEthOracle = UniswapPairOracle(_collateral_weth_oracle_address);
        weth_address = _weth_address;
    }

    function mint1t1OMI(uint256 collateral_amount, uint256 OMI_out_min) external notMintPaused {
        uint256 collateral_amount_d18 = collateral_amount * (10 ** missing_decimals);

        require(OMI.global_collateral_ratio() >= COLLATERAL_RATIO_MAX, "Collateral ratio must be >= 1");
        require((collateral_token.balanceOf(address(this))).sub(unclaimedPoolCollateral).add(collateral_amount) <= pool_ceiling, "[Pool's Closed]: Ceiling reached");
        
        (uint256 OMI_amount_d18) = OMIPoolLibrary.calcMint1t1OMI(
            getCollateralPrice(),
            collateral_amount_d18
        ); 

        OMI_amount_d18 = (OMI_amount_d18.mul(uint(1e6).sub(minting_fee))).div(1e6);
        require(OMI_out_min <= OMI_amount_d18, "Slippage limit reached");

        collateral_token.transferFrom(msg.sender, address(this), collateral_amount);
        OMI.pool_mint(msg.sender, OMI_amount_d18);
    }

    function mintAlgorithmicOMI(uint256 OMS_amount_d18, uint256 OMI_out_min) external notMintPaused {
        uint256 OMS_price = OMI.OMS_price();
        require(OMI.global_collateral_ratio() == 0, "Collateral ratio must be 0");
        
        (uint256 OMI_amount_d18) = OMIPoolLibrary.calcMintAlgorithmicOMI(
            OMS_price, 
            OMS_amount_d18
        );

        OMI_amount_d18 = (OMI_amount_d18.mul(uint(1e6).sub(minting_fee))).div(1e6);
        require(OMI_out_min <= OMI_amount_d18, "Slippage limit reached");

        OMS.pool_burn_from(msg.sender, OMS_amount_d18);
        OMI.pool_mint(msg.sender, OMI_amount_d18);
    }

    function mintFractionalOMI(uint256 collateral_amount, uint256 OMS_amount, uint256 OMI_out_min) external notMintPaused {
        uint256 OMS_price = OMI.OMS_price();
        uint256 global_collateral_ratio = OMI.global_collateral_ratio();

        require(global_collateral_ratio < COLLATERAL_RATIO_MAX && global_collateral_ratio > 0, "Collateral ratio needs to be between .000001 and .999999");
        require(collateral_token.balanceOf(address(this)).sub(unclaimedPoolCollateral).add(collateral_amount) <= pool_ceiling, "Pool ceiling reached, no more OMI can be minted with this collateral");

        uint256 collateral_amount_d18 = collateral_amount * (10 ** missing_decimals);
        OMIPoolLibrary.MintFF_Params memory input_params = OMIPoolLibrary.MintFF_Params(
            OMS_price,
            getCollateralPrice(),
            OMS_amount,
            collateral_amount_d18,
            global_collateral_ratio
        );

        (uint256 mint_amount, uint256 OMS_needed) = OMIPoolLibrary.calcMintFractionalOMI(input_params);

        mint_amount = (mint_amount.mul(uint(1e6).sub(minting_fee))).div(1e6);
        require(OMS_needed <= OMS_amount, "Not enough OMS inputted");
        require(OMI_out_min <= mint_amount, "Slippage limit reached");

        OMS.pool_burn_from(msg.sender, OMS_needed);
        collateral_token.transferFrom(msg.sender, address(this), collateral_amount);
        OMI.pool_mint(msg.sender, mint_amount);
    }

    function redeem1t1OMI(uint256 OMI_amount, uint256 COLLATERAL_out_min) external notRedeemPaused {
        require(OMI.global_collateral_ratio() == COLLATERAL_RATIO_MAX, "Collateral ratio must be == 1");

        uint256 OMI_amount_precision = OMI_amount.div(10 ** missing_decimals);
        (uint256 collateral_needed) = OMIPoolLibrary.calcRedeem1t1OMI(
            getCollateralPrice(),
            OMI_amount_precision
        );

        collateral_needed = (collateral_needed.mul(uint(1e6).sub(redemption_fee))).div(1e6);
        require(collateral_needed <= collateral_token.balanceOf(address(this)).sub(unclaimedPoolCollateral), "Not enough collateral in pool");
        require(COLLATERAL_out_min <= collateral_needed, "Slippage limit reached");

        redeemCollateralBalances[msg.sender] = redeemCollateralBalances[msg.sender].add(collateral_needed);
        unclaimedPoolCollateral = unclaimedPoolCollateral.add(collateral_needed);
        lastRedeemed[msg.sender] = block.number;
        
        OMI.pool_burn_from(msg.sender, OMI_amount);
    }

    function redeemFractionalOMI(uint256 OMI_amount, uint256 OMS_out_min, uint256 COLLATERAL_out_min) external notRedeemPaused {
        uint256 OMS_price = OMI.OMS_price();
        uint256 global_collateral_ratio = OMI.global_collateral_ratio();

        require(global_collateral_ratio < COLLATERAL_RATIO_MAX && global_collateral_ratio > 0, "Collateral ratio needs to be between .000001 and .999999");
        uint256 col_price_usd = getCollateralPrice();

        uint256 OMI_amount_post_fee = (OMI_amount.mul(uint(1e6).sub(redemption_fee))).div(PRICE_PRECISION);

        uint256 OMS_dollar_value_d18 = OMI_amount_post_fee.sub(OMI_amount_post_fee.mul(global_collateral_ratio).div(PRICE_PRECISION));
        uint256 OMS_amount = OMS_dollar_value_d18.mul(PRICE_PRECISION).div(OMS_price);

        uint256 OMI_amount_precision = OMI_amount_post_fee.div(10 ** missing_decimals);
        uint256 collateral_dollar_value = OMI_amount_precision.mul(global_collateral_ratio).div(PRICE_PRECISION);
        uint256 collateral_amount = collateral_dollar_value.mul(PRICE_PRECISION).div(col_price_usd);


        require(OMS_out_min <= OMS_amount, "Slippage limit reached [OMS]");
        require(COLLATERAL_out_min <= collateral_amount, "Slippage limit reached [collateral]");
        require(collateral_amount <= collateral_token.balanceOf(address(this)).sub(unclaimedPoolCollateral), "Not enough collateral in pool");

        redeemCollateralBalances[msg.sender] = redeemCollateralBalances[msg.sender].add(collateral_amount);
        unclaimedPoolCollateral = unclaimedPoolCollateral.add(collateral_amount);

        redeemOMSBalances[msg.sender] = redeemOMSBalances[msg.sender].add(OMS_amount);
        unclaimedPoolOMS = unclaimedPoolOMS.add(OMS_amount);

        lastRedeemed[msg.sender] = block.number;
        
        OMI.pool_burn_from(msg.sender, OMI_amount);
        OMS.pool_mint(address(this), OMS_amount);
    }

    function redeemAlgorithmicOMI(uint256 OMI_amount, uint256 OMS_out_min) external notRedeemPaused {
        uint256 OMS_price = OMI.OMS_price();
        uint256 global_collateral_ratio = OMI.global_collateral_ratio();

        require(global_collateral_ratio == 0, "Collateral ratio must be 0"); 
        uint256 OMS_dollar_value_d18 = OMI_amount;

        OMS_dollar_value_d18 = (OMS_dollar_value_d18.mul(uint(1e6).sub(redemption_fee))).div(PRICE_PRECISION); 

        uint256 OMS_amount = OMS_dollar_value_d18.mul(PRICE_PRECISION).div(OMS_price);
        
        redeemOMSBalances[msg.sender] = redeemOMSBalances[msg.sender].add(OMS_amount);
        unclaimedPoolOMS = unclaimedPoolOMS.add(OMS_amount);
        
        lastRedeemed[msg.sender] = block.number;
        
        require(OMS_out_min <= OMS_amount, "Slippage limit reached");
        OMI.pool_burn_from(msg.sender, OMI_amount);
        OMS.pool_mint(address(this), OMS_amount);
    }
    
    function collectRedemption() external {
        require((lastRedeemed[msg.sender].add(redemption_delay)) <= block.number, "Must wait for redemption_delay blocks before collecting redemption");
        uint CollateralAmount;
        uint OMSAmount;
        bool sendCollateral = false;
        bool sendOMS = false;

        if(redeemOMSBalances[msg.sender] > 0){
            OMSAmount = redeemOMSBalances[msg.sender];
            redeemOMSBalances[msg.sender] = 0;
            unclaimedPoolOMS = unclaimedPoolOMS.sub(OMSAmount);

            sendOMS = true;
        }
        
        if(redeemCollateralBalances[msg.sender] > 0){
            CollateralAmount = redeemCollateralBalances[msg.sender];
            redeemCollateralBalances[msg.sender] = 0;
            unclaimedPoolCollateral = unclaimedPoolCollateral.sub(CollateralAmount);

            sendCollateral = true;
        }

        if(sendOMS == true){
            OMS.transfer(msg.sender, OMSAmount);
        }
        if(sendCollateral == true){
            collateral_token.transfer(msg.sender, CollateralAmount);
        }
    }

    function recollateralizeOMI(uint256 collateral_amount, uint256 OMS_out_min) external {
        require(recollateralizePaused == false, "Recollateralize is paused");
        uint256 collateral_amount_d18 = collateral_amount * (10 ** missing_decimals);
        uint256 OMS_price = OMI.OMS_price();
        uint256 OMI_total_supply = OMI.totalSupply();
        uint256 global_collateral_ratio = OMI.global_collateral_ratio();
        uint256 global_collat_value = OMI.globalCollateralValue();

        (uint256 collateral_units, uint256 amount_to_recollat) = OMIPoolLibrary.calcRecollateralizeOMIInner(
            collateral_amount_d18,
            getCollateralPrice(),
            global_collat_value,
            OMI_total_supply,
            global_collateral_ratio
        ); 

        uint256 collateral_units_precision = collateral_units.div(10 ** missing_decimals);
        uint256 OMS_paid_back = amount_to_recollat.mul(uint(1e6).add(bonus_rate).sub(recollat_fee)).div(OMS_price);

        require(OMS_out_min <= OMS_paid_back, "Slippage limit reached");
        collateral_token.transferFrom(msg.sender, address(this), collateral_units_precision);
        OMS.pool_mint(msg.sender, OMS_paid_back);
        
    }

    function buyBackOMS(uint256 OMS_amount, uint256 COLLATERAL_out_min) external {
        require(buyBackPaused == false, "Buyback is paused");
        uint256 OMS_price = OMI.OMS_price();
    
        OMIPoolLibrary.BuybackOMS_Params memory input_params = OMIPoolLibrary.BuybackOMS_Params(
            availableExcessCollatDV(),
            OMS_price,
            getCollateralPrice(),
            OMS_amount
        );

        (uint256 collateral_equivalent_d18) = (OMIPoolLibrary.calcBuyBackOMS(input_params)).mul(uint(1e6).sub(buyback_fee)).div(1e6);
        uint256 collateral_precision = collateral_equivalent_d18.div(10 ** missing_decimals);

        require(COLLATERAL_out_min <= collateral_precision, "Slippage limit reached");
        OMS.pool_burn_from(msg.sender, OMS_amount);
        collateral_token.transfer(msg.sender, collateral_precision);
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function toggleMinting() external {
        require(hasRole(MINT_PAUSER, msg.sender));
        mintPaused = !mintPaused;
    }

    function toggleRedeeming() external {
        require(hasRole(REDEEM_PAUSER, msg.sender));
        redeemPaused = !redeemPaused;
    }

    function toggleRecollateralize() external {
        require(hasRole(RECOLLATERALIZE_PAUSER, msg.sender));
        recollateralizePaused = !recollateralizePaused;
    }
    
    function toggleBuyBack() external {
        require(hasRole(BUYBACK_PAUSER, msg.sender));
        buyBackPaused = !buyBackPaused;
    }

    function toggleCollateralPrice(uint256 _new_price) external {
        require(hasRole(COLLATERAL_PRICE_PAUSER, msg.sender));
        if(collateralPricePaused == false){
            pausedPrice = _new_price;
        } else {
            pausedPrice = 0;
        }
        collateralPricePaused = !collateralPricePaused;
    }

    function setPoolParameters(uint256 new_ceiling, uint256 new_bonus_rate, uint256 new_redemption_delay, uint256 new_mint_fee, uint256 new_redeem_fee, uint256 new_buyback_fee, uint256 new_recollat_fee) external onlyByOwnerOrGovernance {
        pool_ceiling = new_ceiling;
        bonus_rate = new_bonus_rate;
        redemption_delay = new_redemption_delay;
        minting_fee = new_mint_fee;
        redemption_fee = new_redeem_fee;
        buyback_fee = new_buyback_fee;
        recollat_fee = new_recollat_fee;
    }

    function setTimelock(address new_timelock) external onlyByOwnerOrGovernance {
        timelock_address = new_timelock;
    }

    function setOwner(address _owner_address) external onlyByOwnerOrGovernance {
        owner_address = _owner_address;
    }

    /* ========== EVENTS ========== */

}