// SPDX-License-Identifier: MIT
pragma solidity ^0.6.10;
pragma experimental ABIEncoderV2;



import "../Common/Context.sol";
import "../ERC20/IERC20.sol";
import "../ERC20/ERC20Custom.sol";
import "../ERC20/ERC20.sol";
import "../Math/SafeMath.sol";
import "../OMS/OMS.sol";
import "./Pools/OMIPool.sol";
import "../Oracle/UniswapPairOracle.sol";
import "../Oracle/ChainlinkETHUSDPriceConsumer.sol";
import "../Governance/AccessControl.sol";

contract OMIStablecoin is ERC20Custom, AccessControl {
    using SafeMath for uint256;

    /* ========== STATE VARIABLES ========== */
    enum PriceChoice { OMI, OMS }
    ChainlinkETHUSDPriceConsumer private eth_usd_pricer;
    uint8 private eth_usd_pricer_decimals;
    UniswapPairOracle private OMIEthOracle;
    UniswapPairOracle private OMSEthOracle;
    string public symbol;
    string public name;
    uint8 public constant decimals = 18;
    address public owner_address;
    address public creator_address;
    address public timelock_address; 
    address public controller_address; 
    address public OMS_address;
    address public OMI_eth_oracle_address;
    address public OMS_eth_oracle_address;
    address public weth_address;
    address public eth_usd_consumer_address;
    uint256 public constant genesis_supply = 2000000e18; 

    
    address[] public OMI_pools_array;

    
    mapping(address => bool) public OMI_pools; 

    
    uint256 private constant PRICE_PRECISION = 1e6;
    
    uint256 public global_collateral_ratio; 
    uint256 public refresh_cooldown; 
    uint256 public minting_fee; 
    uint256 public OMI_step; 
    uint256 public redemption_fee; 
    uint256 public price_band; 
    uint256 public price_target; 

    address public DEFAULT_ADMIN_ADDRESS;
    bytes32 public constant COLLATERAL_RATIO_PAUSER = keccak256("COLLATERAL_RATIO_PAUSER");
    bool public collateral_ratio_paused = false;

    /* ========== MODIFIERS ========== */

    modifier onlyCollateralRatioPauser() {
        require(hasRole(COLLATERAL_RATIO_PAUSER, msg.sender));
        _;
    }

    modifier onlyPools() {
       require(OMI_pools[msg.sender] == true, "Only OMI pools can call this function");
        _;
    } 
    
    modifier onlyByOwnerOrGovernance() {
        require(msg.sender == owner_address || msg.sender == timelock_address || msg.sender == controller_address, "You are not the owner, controller, or the governance timelock");
        _;
    }

    modifier onlyByOwnerGovernanceOrPool() {
        require(
            msg.sender == owner_address 
            || msg.sender == timelock_address 
            || OMI_pools[msg.sender] == true, 
            "You are not the owner, the governance timelock, or a pool");
        _;
    }

    /* ========== CONSTRUCTOR ========== */

    constructor(
        string memory _name,
        string memory _symbol,
        address _creator_address,
        address _timelock_address
    ) public {
        name = _name;
        symbol = _symbol;
        creator_address = _creator_address;
        timelock_address = _timelock_address;
        _setupRole(DEFAULT_ADMIN_ROLE, _msgSender());
        DEFAULT_ADMIN_ADDRESS = _msgSender();
        owner_address = _creator_address;
        _mint(creator_address, genesis_supply);
        grantRole(COLLATERAL_RATIO_PAUSER, creator_address);
        grantRole(COLLATERAL_RATIO_PAUSER, timelock_address);
        OMI_step = 2500; 
        global_collateral_ratio = 1000000; 
        refresh_cooldown = 3600; 
        price_target = 1000000; 
        price_band = 5000; 
    }

    /* ========== VIEWS ========== */

    function OMI_price() public view returns (uint256) {
        return oracle_price(PriceChoice.OMI);
    }

    function OMS_price()  public view returns (uint256) {
        return oracle_price(PriceChoice.OMS);
    }


    
    function OMI_info() public view returns (uint256, uint256, uint256, uint256, uint256, uint256, uint256, uint256) {
        return (
            oracle_price(PriceChoice.OMI), 
            oracle_price(PriceChoice.OMS), 
            totalSupply(), 
            global_collateral_ratio, 
            globalCollateralValue(), 
            minting_fee, 
            redemption_fee, 
            uint256(eth_usd_pricer.getLatestPrice()).mul(PRICE_PRECISION).div(uint256(10) ** eth_usd_pricer_decimals) 
        );
    }

    function oracle_price(PriceChoice choice) internal view returns (uint256) {
        uint256 eth_usd_price = uint256(eth_usd_pricer.getLatestPrice()).mul(PRICE_PRECISION).div(uint256(10) ** eth_usd_pricer_decimals);
        uint256 price_vs_eth;

        if (choice == PriceChoice.OMI) {
            price_vs_eth = uint256(OMIEthOracle.consult(weth_address, PRICE_PRECISION)); 
        }
        else if (choice == PriceChoice.OMS) {
            price_vs_eth = uint256(OMSEthOracle.consult(weth_address, PRICE_PRECISION)); 
        }
        else revert("INVALID PRICE CHOICE. Needs to be either 0 (OMI) or 1 (OMS)");

        return eth_usd_price.mul(PRICE_PRECISION).div(price_vs_eth);
    }


    function eth_usd_price() public view returns (uint256) {
        return uint256(eth_usd_pricer.getLatestPrice()).mul(PRICE_PRECISION).div(uint256(10) ** eth_usd_pricer_decimals);
    }
    
    function globalCollateralValue() public view returns (uint256) {
        uint256 total_collateral_value_d18 = 0; 

        for (uint i = 0; i < OMI_pools_array.length; i++){ 
            
            if (OMI_pools_array[i] != address(0)){
                total_collateral_value_d18 = total_collateral_value_d18.add(OMIPool(OMI_pools_array[i]).collatDollarBalance());
            }

        }
        return total_collateral_value_d18;
    }

    /* ========== PUBLIC FUNCTIONS ========== */
    
    
    uint256 public last_call_time; 
    function refreshCollateralRatio() public {
        require(collateral_ratio_paused == false, "Collateral Ratio has been paused");
        uint256 OMI_price_cur = OMI_price();
        require(block.timestamp - last_call_time >= refresh_cooldown, "Must wait for the refresh cooldown since last refresh");

        
        
        if (OMI_price_cur > price_target.add(price_band)) { 
            if(global_collateral_ratio <= OMI_step){ 
                global_collateral_ratio = 0;
            } else {
                global_collateral_ratio = global_collateral_ratio.sub(OMI_step);
            }
        } else if (OMI_price_cur < price_target.sub(price_band)) { 
            if(global_collateral_ratio.add(OMI_step) >= 1000000){
                global_collateral_ratio = 1000000; 
            } else {
                global_collateral_ratio = global_collateral_ratio.add(OMI_step);
            }
        }

        last_call_time = block.timestamp; 
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    
    function pool_burn_from(address b_address, uint256 b_amount) public onlyPools {
        super._burnFrom(b_address, b_amount);
        emit OMIBurned(b_address, msg.sender, b_amount);
    }

    
    function pool_mint(address m_address, uint256 m_amount) public onlyPools {
        super._mint(m_address, m_amount);
        emit OMIMinted(msg.sender, m_address, m_amount);
    }

    
    function addPool(address pool_address) public onlyByOwnerOrGovernance {
        require(OMI_pools[pool_address] == false, "address already exists");
        OMI_pools[pool_address] = true; 
        OMI_pools_array.push(pool_address);
    }

    
    function removePool(address pool_address) public onlyByOwnerOrGovernance {
        require(OMI_pools[pool_address] == true, "address doesn't exist already");
        
        
        delete OMI_pools[pool_address];

        
        for (uint i = 0; i < OMI_pools_array.length; i++){ 
            if (OMI_pools_array[i] == pool_address) {
                OMI_pools_array[i] = address(0); 
                break;
            }
        }
    }

    function setOwner(address _owner_address) external onlyByOwnerOrGovernance {
        owner_address = _owner_address;
    }

    function setRedemptionFee(uint256 red_fee) public onlyByOwnerOrGovernance {
        redemption_fee = red_fee;
    }

    function setMintingFee(uint256 min_fee) public onlyByOwnerOrGovernance {
        minting_fee = min_fee;
    }  

    function setOMIStep(uint256 _new_step) public onlyByOwnerOrGovernance {
        OMI_step = _new_step;
    }  

    function setPriceTarget (uint256 _new_price_target) public onlyByOwnerOrGovernance {
        price_target = _new_price_target;
    }

    function setRefreshCooldown(uint256 _new_cooldown) public onlyByOwnerOrGovernance {
    	refresh_cooldown = _new_cooldown;
    }

    function setOMSAddress(address _OMS_address) public onlyByOwnerOrGovernance {
        OMS_address = _OMS_address;
    }

    function setETHUSDOracle(address _eth_usd_consumer_address) public onlyByOwnerOrGovernance {
        eth_usd_consumer_address = _eth_usd_consumer_address;
        eth_usd_pricer = ChainlinkETHUSDPriceConsumer(eth_usd_consumer_address);
        eth_usd_pricer_decimals = eth_usd_pricer.getDecimals();
    }

    function setTimelock(address new_timelock) external onlyByOwnerOrGovernance {
        timelock_address = new_timelock;
    }

    function setController(address _controller_address) external onlyByOwnerOrGovernance {
        controller_address = _controller_address;
    }

    function setPriceBand(uint256 _price_band) external onlyByOwnerOrGovernance {
        price_band = _price_band;
    }

    
    function setOMIEthOracle(address _OMI_oracle_addr, address _weth_address) public onlyByOwnerOrGovernance {
        OMI_eth_oracle_address = _OMI_oracle_addr;
        OMIEthOracle = UniswapPairOracle(_OMI_oracle_addr); 
        weth_address = _weth_address;
    }

    
    function setOMSEthOracle(address _OMS_oracle_addr, address _weth_address) public onlyByOwnerOrGovernance {
        OMS_eth_oracle_address = _OMS_oracle_addr;
        OMSEthOracle = UniswapPairOracle(_OMS_oracle_addr);
        weth_address = _weth_address;
    }

    function toggleCollateralRatio() public onlyCollateralRatioPauser {
        collateral_ratio_paused = !collateral_ratio_paused;
    }

    /* ========== EVENTS ========== */

    
    event OMIBurned(address indexed from, address indexed to, uint256 amount);

    
    event OMIMinted(address indexed from, address indexed to, uint256 amount);
}
