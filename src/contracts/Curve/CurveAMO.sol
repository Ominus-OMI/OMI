// SPDX-License-Identifier: MIT
pragma solidity ^0.6.10;
pragma experimental ABIEncoderV2;

// NOTE: Gauge and CRV related methods have been commented out here and saved until V2, since this is
// almost a chicken-and-egg problem (need to be large enough to qualify for one first)

import "./IStableSwap3Pool.sol";
import "./IMetaImplementationUSD.sol";
import "../ERC20/ERC20.sol";
import "../OMI/OMI.sol";
import "../OMS/OMS.sol";
import "../Math/SafeMath.sol";

contract CurveAMO is AccessControl {
    using SafeMath for uint256;

    /* ========== STATE VARIABLES ========== */

    IMetaImplementationUSD private OMI3crv_metapool;
    IStableSwap3Pool private three_pool;
    ERC20 private three_pool_erc20;
    OMIStablecoin private OMI;
    OMIPool private pool;
    OMIShares private OMS;
    ERC20 private collateral_token;
    ERC20 private CRV = ERC20(0xD533a949740bb3306d119CC777fa900bA034cd52);

    address public owner_address;
    address public three_pool_token_address;
    address public OMI_contract_address;
    address public three_pool_address;
    address public timelock_address;
    address public collateral_token_address;
    address public OMS_contract_address;
    address public OMI3crv_metapool_address;
    uint256 public burned_OMI_historical = 0;
    address public pool_address;
    uint256 public minted_OMI_historical = 0;
    uint256 public liq_slippage_3crv = 900000;
    uint256 public max_OMI_outstanding = uint256(2000000e18);
    uint256 public borrowed_collat_historical = 0;
    uint256 public returned_collat_historical = 0;
    uint256 public collat_borrow_cap = uint256(1000000e6);
    uint256 public min_cr = 850000;
    uint256 private missing_decimals;
    uint256 private constant PRICE_PRECISION = 1e6;
    address public custodian_address;
    bool public custom_floor = false;    
    uint256 public OMI_floor;
    uint256 public rem_liq_slippage_metapool = 950000;
    int128 public THREE_POOL_COIN_INDEX = 1;
    uint256 public add_liq_slippage_metapool = 950000;
    bool public set_discount = false;
    uint256 public discount_rate;

    /* ========== CONSTRUCTOR ========== */

    constructor(
        address _OMI_contract_address,
        address _OMS_contract_address,
        address _collateral_address,
        address _creator_address,
        address _custodian_address,
        address _timelock_address,
        address _OMI3crv_metapool_address,
        address _three_pool_address,
        address _three_pool_token_address,
        address _pool_address
    ) public {
        OMI = OMIStablecoin(_OMI_contract_address);
        OMS = OMIShares(_OMS_contract_address);
        OMS_contract_address = _OMS_contract_address;
        OMI_contract_address = _OMI_contract_address;
        collateral_token_address = _collateral_address;
        collateral_token = ERC20(_collateral_address);
        missing_decimals = uint(18).sub(collateral_token.decimals());
        custodian_address = _custodian_address;
        timelock_address = _timelock_address;
        owner_address = _creator_address;

        OMI3crv_metapool_address = _OMI3crv_metapool_address;
        OMI3crv_metapool = IMetaImplementationUSD(_OMI3crv_metapool_address);
        three_pool_address = _three_pool_address;
        three_pool = IStableSwap3Pool(_three_pool_address);
        three_pool_token_address = _three_pool_token_address;
        three_pool_erc20 = ERC20(_three_pool_token_address);
        pool_address = _pool_address;
        pool = OMIPool(_pool_address);

    }

    /* ========== MODIFIERS ========== */

    modifier onlyByOwnerOrGovernance() {
        require(msg.sender == timelock_address || msg.sender == owner_address, "You are not the owner or the governance timelock");
        _;
    }

    modifier onlyCustodian() {
        require(msg.sender == custodian_address, "You are not the rewards custodian");
        _;
    }

    /* ========== VIEWS ========== */

    function showAllocations() public view returns (uint256[10] memory return_arr) {
        uint256 lp_owned = OMI3crv_metapool.balanceOf(address(this));

        uint256 OMI3crv_supply = OMI3crv_metapool.totalSupply();
        uint256 OMI_withdrawable;
        uint256 _3pool_withdrawable;
        (OMI_withdrawable, _3pool_withdrawable, ) = iterate();
        if (OMI3crv_supply > 0) {
            _3pool_withdrawable = _3pool_withdrawable.mul(lp_owned).div(OMI3crv_supply);
            OMI_withdrawable = OMI_withdrawable.mul(lp_owned).div(OMI3crv_supply);
        }
        else _3pool_withdrawable = 0;
         
        uint256 OMI_in_contract = OMI.balanceOf(address(this));
        uint256 OMI_total = OMI_withdrawable.add(OMI_in_contract);
        uint256 usdc_in_contract = collateral_token.balanceOf(address(this));
        uint256 usdc_withdrawable = _3pool_withdrawable.mul(three_pool.get_virtual_price()).div(1e18).div(10 ** missing_decimals);
        uint256 usdc_subtotal = usdc_in_contract.add(usdc_withdrawable);
        uint256 usdc_total;
        {
            uint256 OMI_bal = OMIBalance();
            usdc_total = usdc_subtotal + (OMI_in_contract.add(OMI_withdrawable)).mul(OMIDiscountRate()).div(1e6 * (10 ** missing_decimals));
        }

        return [
            lp_owned, 
            OMI_withdrawable, 
            usdc_in_contract, 
            usdc_withdrawable, 
            usdc_subtotal, 
            OMI_total, 
            usdc_total, 
            OMI_in_contract, 
            OMI3crv_supply, 
            _3pool_withdrawable 
        ];
    }

    bool public override_collat_balance = false;
    uint256 public override_collat_balance_amount;
    function collatDollarBalance() public view returns (uint256) {
        if(override_collat_balance){
            return override_collat_balance_amount;
        }
        return (showAllocations()[6] * (10 ** missing_decimals));
    }

    function get_D() public view returns (uint256) {
        uint256 _A = OMI3crv_metapool.A_precise();
        uint256 A_PRECISION = 100;
        uint256[2] memory _xp = [three_pool_erc20.balanceOf(OMI3crv_metapool_address), OMI.balanceOf(OMI3crv_metapool_address)];

        uint256 N_COINS = 2;
        uint256 S;
        for(uint i = 0; i < N_COINS; i++){
            S += _xp[i];
        }
        if(S == 0){
            return 0;
        }
        uint256 D = S;
        uint256 Ann = N_COINS * _A;
        
        uint256 Dprev = 0;
        uint256 D_P;
        for(uint i = 0; i < 256; i++){
            D_P = D;
            for(uint j = 0; j < N_COINS; j++){
                D_P = D * D / (_xp[j] * N_COINS);
            }
            Dprev = D;
            D = (Ann * S / A_PRECISION + D_P * N_COINS) * D / ((Ann - A_PRECISION) * D / A_PRECISION + (N_COINS + 1) * D_P);
            if(D > Dprev){
                if(D - Dprev <= 1){
                    return D;
                }
            } else {
                if(Dprev - D <= 1){
                    return D;
                }
            }
        }

        revert("Convergence not reached");
    }
    uint256 public convergence_window = 1e18; 
    function iterate() public view returns (uint256, uint256, uint256) {
        uint256 OMI_balance = OMI.balanceOf(OMI3crv_metapool_address);
        uint256 crv3_balance = three_pool_erc20.balanceOf(OMI3crv_metapool_address);

        uint256 floor_price_OMI = uint(1e18).mul(OMIFloor()).div(1e8);
        
        uint256 crv3_received;
        uint256 dollar_value; 
        uint256 virtual_price = three_pool.get_virtual_price();
        for(uint i = 0; i < 256; i++){
            crv3_received = OMI3crv_metapool.get_dy(0, 1, 1e16, [OMI_balance, crv3_balance]);
            dollar_value = crv3_received.mul(1e18).div(virtual_price);
            if(dollar_value <= floor_price_OMI.add(convergence_window)){
                return (OMI_balance, crv3_balance, i);
            }
            uint256 OMI_to_swap = OMI_balance.div(10);
            crv3_balance = crv3_balance.sub(OMI3crv_metapool.get_dy(0, 1, OMI_to_swap, [OMI_balance, crv3_balance]));
            OMI_balance = OMI_balance.add(OMI_to_swap);
        }
        revert("Didn't find hypothetical point on curve within 256 rounds");
    }

    function OMIFloor() public view returns (uint256) {
        if(custom_floor){
            return OMI_floor;
        } else {
            return OMI.global_collateral_ratio();
        }
    }

    function OMIDiscountRate() public view returns (uint256) {
        if(set_discount){
            return discount_rate;
        } else {
            return OMI.global_collateral_ratio();
        }
    }
    function OMIBalance() public view returns (uint256) {
        if (minted_OMI_historical >= burned_OMI_historical) return minted_OMI_historical.sub(burned_OMI_historical);
        else return 0;
    }

    function collateralBalance() public view returns (uint256) {
        if (borrowed_collat_historical >= returned_collat_historical) return borrowed_collat_historical.sub(returned_collat_historical);
        else return 0;
    }

    function mintRedeemPart1(uint256 OMI_amount) public onlyByOwnerOrGovernance {
        uint256 col_price_usd = pool.getCollateralPrice();
        uint256 redemption_fee = pool.redemption_fee();
        uint256 global_collateral_ratio = OMI.global_collateral_ratio();
        uint256 redeem_amount_E6 = (OMI_amount.mul(uint256(1e8).sub(redemption_fee))).div(1e8).div(10 ** missing_decimals);
        uint256 expected_collat_amount = redeem_amount_E6.mul(global_collateral_ratio).div(1e8);
        expected_collat_amount = expected_collat_amount.mul(1e8).div(col_price_usd);

        require(collateralBalance().add(expected_collat_amount) <= collat_borrow_cap, "Borrow cap reached");
        borrowed_collat_historical = borrowed_collat_historical.add(expected_collat_amount);


        OMI.pool_mint(address(this), OMI_amount);
        OMI.approve(address(pool), OMI_amount);
        pool.redeemFractionalOMI(OMI_amount, 0, 0);
    }

    function giveCollatBack(uint256 amount) public onlyByOwnerOrGovernance {
        collateral_token.transfer(address(pool), amount);
        returned_collat_historical = returned_collat_historical.add(amount);
    }
   
    function burnOMI(uint256 OMI_amount) public onlyByOwnerOrGovernance {
        OMI.burn(OMI_amount);
        burned_OMI_historical = burned_OMI_historical.add(OMI_amount);
    }

    function mintRedeemPart2() public onlyByOwnerOrGovernance {
        pool.collectRedemption();
    }
   
    function burnOMS(uint256 amount) public onlyByOwnerOrGovernance {
        OMS.approve(address(this), amount);
        OMS.pool_burn_from(address(this), amount);
    }

    function metapoolDeposit(uint256 _OMI_amount, uint256 _collateral_amount) public onlyByOwnerOrGovernance returns (uint256 metapool_LP_received) {

        OMI.pool_mint(address(this), _OMI_amount);
        minted_OMI_historical = minted_OMI_historical.add(_OMI_amount);
        require(OMIBalance() <= max_OMI_outstanding, "Too much OMI would be minted [max_OMI_outstanding reached]");

        uint256 threeCRV_received = 0;
        if (_collateral_amount > 0) {
    
            collateral_token.approve(address(three_pool), _collateral_amount);

    
            uint256[3] memory three_pool_collaterals;
            three_pool_collaterals[uint256(THREE_POOL_COIN_INDEX)] = _collateral_amount;
            {
                uint256 min_3pool_out = (_collateral_amount * (10 ** missing_decimals)).mul(liq_slippage_3crv).div(PRICE_PRECISION);
                three_pool.add_liquidity(three_pool_collaterals, min_3pool_out);
            }
            threeCRV_received = three_pool_erc20.balanceOf(address(this));

            three_pool_erc20.approve(OMI3crv_metapool_address, 0);
            three_pool_erc20.approve(OMI3crv_metapool_address, threeCRV_received);
        }
        
        OMI.approve(OMI3crv_metapool_address, _OMI_amount);

        {
            uint256 min_lp_out = (_OMI_amount.add(threeCRV_received)).mul(add_liq_slippage_metapool).div(PRICE_PRECISION);
            metapool_LP_received = OMI3crv_metapool.add_liquidity([_OMI_amount, threeCRV_received], min_lp_out);
        }

        uint256 current_collateral_E18 = (OMI.globalCollateralValue()).mul(10 ** missing_decimals);
        uint256 cur_OMI_supply = OMI.totalSupply();
        uint256 new_cr = (current_collateral_E18.mul(PRICE_PRECISION)).div(cur_OMI_supply);
        require (new_cr >= min_cr, "Minting caused the collateral ratio to be too low");
        
        return metapool_LP_received;
    }

    function metapoolWithdrawAtCurRatio(uint256 _metapool_lp_in, bool burn_the_OMI, uint256 min_OMI, uint256 min_3pool) public onlyByOwnerOrGovernance returns (uint256 OMI_received) {
        OMI3crv_metapool.approve(address(this), _metapool_lp_in);
        uint256 three_pool_received;
        {
            uint256[2] memory result_arr = OMI3crv_metapool.remove_liquidity(_metapool_lp_in, [min_OMI, min_3pool]);
            OMI_received = result_arr[0];
            three_pool_received = result_arr[1];
        }
        three_pool_erc20.approve(address(three_pool), 0);
        three_pool_erc20.approve(address(three_pool), three_pool_received);
        {
            uint256 min_collat_out = three_pool_received.mul(liq_slippage_3crv).div(PRICE_PRECISION * (10 ** missing_decimals));
            three_pool.remove_liquidity_one_coin(three_pool_received, THREE_POOL_COIN_INDEX, min_collat_out);
        }

        if (burn_the_OMI){
            burnOMI(OMI_received);
        }
        
    }

    function metapoolWithdrawOMI(uint256 _metapool_lp_in, bool burn_the_OMI) public onlyByOwnerOrGovernance returns (uint256 OMI_received) {
        uint256 min_OMI_out = _metapool_lp_in.mul(rem_liq_slippage_metapool).div(PRICE_PRECISION);
        OMI_received = OMI3crv_metapool.remove_liquidity_one_coin(_metapool_lp_in, 0, min_OMI_out);

        if (burn_the_OMI){
            burnOMI(OMI_received);
        }
    }

    function metapoolWithdraw3pool(uint256 _metapool_lp_in) public onlyByOwnerOrGovernance {
        uint256 min_3pool_out = _metapool_lp_in.mul(rem_liq_slippage_metapool).div(PRICE_PRECISION);
        OMI3crv_metapool.remove_liquidity_one_coin(_metapool_lp_in, 1, min_3pool_out);
    }

    function three_pool_to_collateral(uint256 _3pool_in) public onlyByOwnerOrGovernance {
        three_pool_erc20.approve(address(three_pool), 0);
        three_pool_erc20.approve(address(three_pool), _3pool_in);
        uint256 min_collat_out = _3pool_in.mul(liq_slippage_3crv).div(PRICE_PRECISION * (10 ** missing_decimals));
        three_pool.remove_liquidity_one_coin(_3pool_in, THREE_POOL_COIN_INDEX, min_collat_out);
    }

    function metapoolWithdrawAndConvert3pool(uint256 _metapool_lp_in) public onlyByOwnerOrGovernance {
        metapoolWithdraw3pool(_metapool_lp_in);
        three_pool_to_collateral(three_pool_erc20.balanceOf(address(this)));
    }

    /* ========== RESTRICTED GOVERNANCE FUNCTIONS ========== */

    function setMiscRewardsCustodian(address _custodian_address) external onlyByOwnerOrGovernance {
        custodian_address = _custodian_address;
    }

    function setPool(address _pool_address) external onlyByOwnerOrGovernance {
        pool_address = _pool_address;
        pool = OMIPool(_pool_address);
    }

    function setTimelock(address new_timelock) external onlyByOwnerOrGovernance {
        timelock_address = new_timelock;
    }

    function setOwner(address _owner_address) external onlyByOwnerOrGovernance {
        owner_address = _owner_address;
    }

    function setThreePool(address _three_pool_address, address _three_pool_token_address) external onlyByOwnerOrGovernance {
        three_pool_address = _three_pool_address;
        three_pool = IStableSwap3Pool(_three_pool_address);
        three_pool_token_address = _three_pool_token_address;
        three_pool_erc20 = ERC20(_three_pool_token_address);
    }

    function setMetapool(address _metapool_address) public onlyByOwnerOrGovernance {
        OMI3crv_metapool_address = _metapool_address;
        OMI3crv_metapool = IMetaImplementationUSD(_metapool_address);
    }

    function setCollatBorrowCap(uint256 _collat_borrow_cap) external onlyByOwnerOrGovernance {
        collat_borrow_cap = _collat_borrow_cap;
    }

    function setMaxOMIOutstanding(uint256 _max_OMI_outstanding) external onlyByOwnerOrGovernance {
        max_OMI_outstanding = _max_OMI_outstanding;
    }

    function setMinimumCollateralRatio(uint256 _min_cr) external onlyByOwnerOrGovernance {
        min_cr = _min_cr;
    }

    function setConvergenceWindow(uint256 _window) external onlyByOwnerOrGovernance {
        convergence_window = _window;
    }

    function setOverrideCollatBalance(bool _state, uint256 _balance) external onlyByOwnerOrGovernance {
        override_collat_balance = _state;
        override_collat_balance_amount = _balance;
    }

    function setCustomFloor(bool _state, uint256 _floor_price) external onlyByOwnerOrGovernance {
        custom_floor = _state;
        OMI_floor = _floor_price;
    }

    function setDiscountRate(bool _state, uint256 _discount_rate) external onlyByOwnerOrGovernance {
        set_discount = _state;
        discount_rate = _discount_rate;
    }

    function setSlippages(uint256 _liq_slippage_3crv, uint256 _add_liq_slippage_metapool, uint256 _rem_liq_slippage_metapool) external onlyByOwnerOrGovernance {
        liq_slippage_3crv = _liq_slippage_3crv;
        add_liq_slippage_metapool = _add_liq_slippage_metapool;
        rem_liq_slippage_metapool = _rem_liq_slippage_metapool;
    }

    function recoverERC20(address tokenAddress, uint256 tokenAmount) external onlyByOwnerOrGovernance {

        ERC20(tokenAddress).transfer(custodian_address, tokenAmount);
        emit Recovered(tokenAddress, tokenAmount);
    }

    /* ========== EVENTS ========== */

    event Recovered(address token, uint256 amount);

}