// SPDX-License-Identifier: MIT
pragma solidity ^0.6.10;
pragma experimental ABIEncoderV2;

import "../../Math/SafeMath.sol";



library OMIPoolLibrary {
    using SafeMath for uint256;

    uint256 private constant PRICE_PRECISION = 1e6;

    // ================ Structs ================
    struct MintFF_Params {
        uint256 OMS_price_usd; 
        uint256 col_price_usd;
        uint256 OMS_amount;
        uint256 collateral_amount;
        uint256 col_ratio;
    }

    struct BuybackOMS_Params {
        uint256 excess_collateral_dollar_value_d18;
        uint256 OMS_price_usd;
        uint256 col_price_usd;
        uint256 OMS_amount;
    }

    // ================ Functions ================

    function calcMint1t1OMI(uint256 col_price, uint256 collateral_amount_d18) public pure returns (uint256) {
        return (collateral_amount_d18.mul(col_price)).div(1e6);
    }

    function calcMintAlgorithmicOMI(uint256 OMS_price_usd, uint256 OMS_amount_d18) public pure returns (uint256) {
        return OMS_amount_d18.mul(OMS_price_usd).div(1e6);
    }

    function calcMintFractionalOMI(MintFF_Params memory params) internal pure returns (uint256, uint256) {
        uint256 OMS_dollar_value_d18;
        uint256 c_dollar_value_d18;
        
        {    
            OMS_dollar_value_d18 = params.OMS_amount.mul(params.OMS_price_usd).div(1e6);
            c_dollar_value_d18 = params.collateral_amount.mul(params.col_price_usd).div(1e6);
        }
        uint calculated_OMS_dollar_value_d18 = 
                    (c_dollar_value_d18.mul(1e6).div(params.col_ratio))
                    .sub(c_dollar_value_d18);

        uint calculated_OMS_needed = calculated_OMS_dollar_value_d18.mul(1e6).div(params.OMS_price_usd);

        return (
            c_dollar_value_d18.add(calculated_OMS_dollar_value_d18),
            calculated_OMS_needed
        );
    }
    function recollateralizeAmount(uint256 total_supply, uint256 global_collateral_ratio, uint256 global_collat_value) public pure returns (uint256) {
        uint256 target_collat_value = total_supply.mul(global_collateral_ratio).div(1e6); 
        return target_collat_value.sub(global_collat_value); 
    }

    function calcRedeem1t1OMI(uint256 col_price_usd, uint256 OMI_amount) public pure returns (uint256) {
        return OMI_amount.mul(1e6).div(col_price_usd);
    }

    function calcBuyBackOMS(BuybackOMS_Params memory params) internal pure returns (uint256) {
        require(params.excess_collateral_dollar_value_d18 > 0, "No excess collateral to buy back!");
        uint256 OMS_dollar_value_d18 = params.OMS_amount.mul(params.OMS_price_usd).div(1e6);
        require(OMS_dollar_value_d18 <= params.excess_collateral_dollar_value_d18, "You are trying to buy back more than the excess!");
        uint256 collateral_equivalent_d18 = OMS_dollar_value_d18.mul(1e6).div(params.col_price_usd);
        return (
            collateral_equivalent_d18
        );

    }

    function calcRecollateralizeOMIInner(
        uint256 collateral_amount, 
        uint256 col_price,
        uint256 global_collat_value,
        uint256 OMI_total_supply,
        uint256 global_collateral_ratio
    ) public pure returns (uint256, uint256) {
        uint256 collat_value_attempted = collateral_amount.mul(col_price).div(1e6);
        uint256 effective_collateral_ratio = global_collat_value.mul(1e6).div(OMI_total_supply); 
        uint256 recollat_possible = (global_collateral_ratio.mul(OMI_total_supply).sub(OMI_total_supply.mul(effective_collateral_ratio))).div(1e6);

        uint256 amount_to_recollat;
        if(collat_value_attempted <= recollat_possible){
            amount_to_recollat = collat_value_attempted;
        } else {
            amount_to_recollat = recollat_possible;
        }

        return (amount_to_recollat.mul(1e6).div(col_price), amount_to_recollat);

    }

}