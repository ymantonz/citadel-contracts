// SPDX-License-Identifier: MIT

pragma solidity 0.8.12;
pragma experimental ABIEncoderV2;

import {IERC20Upgradeable} from "openzeppelin-contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import {AddressUpgradeable} from "openzeppelin-contracts-upgradeable/utils/AddressUpgradeable.sol";
import {SafeERC20Upgradeable} from "openzeppelin-contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import {ERC20Upgradeable} from "openzeppelin-contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ReentrancyGuardUpgradeable} from "openzeppelin-contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import {EnumerableSetUpgradeable} from "openzeppelin-contracts-upgradeable/utils/structs/EnumerableSetUpgradeable.sol";

import "./lib/GlobalAccessControlManaged.sol";

import "./interfaces/citadel/ISupplySchedule.sol";
import "./interfaces/citadel/ICitadelToken.sol";
import "./interfaces/badger/IVault.sol";
import "./interfaces/citadel/IStakedCitadelLocker.sol";

/**
Supply schedules are defined in terms of Epochs
*/
contract CitadelMinter is
    GlobalAccessControlManaged,
    ReentrancyGuardUpgradeable
{
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using EnumerableSetUpgradeable for EnumerableSetUpgradeable.AddressSet;

    bytes32 public constant CONTRACT_GOVERNANCE_ROLE =
        keccak256("CONTRACT_GOVERNANCE_ROLE");
    bytes32 public constant POLICY_OPERATIONS_ROLE =
        keccak256("POLICY_OPERATIONS_ROLE");

    ICitadelToken public citadelToken;
    IVault public xCitadel;
    IStakedCitadelLocker public xCitadelLocker;
    ISupplySchedule public supplySchedule;

    uint256 public lastMintTimestamp;

    uint256 constant MAX_BPS = 10000;

    EnumerableSetUpgradeable.AddressSet internal fundingPools;
    mapping(address => uint256) public fundingPoolWeights;
    uint256 public totalFundingPoolWeight;

    uint256 public fundingBps;
    uint256 public stakingBps;
    uint256 public lockingBps;

    /// ==================
    /// ===== Events =====
    /// ==================

    event FundingPoolWeightSet(
        address pool,
        uint256 weight,
        uint256 totalFundingPoolWeight
    );
    event CitadelDistributionSplitSet(
        uint256 fundingBps,
        uint256 stakingBps,
        uint256 lockingBps
    );
    event CitadelDistribution(
        uint256 fundingAmount,
        uint256 stakingAmount,
        uint256 lockingAmount
    );

    event CitadelDistributionToFunding(
        uint256 startTime,
        uint256 endTime,
        uint256 citadelAmount
    );
    event CitadelDistributionToFundingPool(
        uint256 startTime,
        uint256 endTime,
        address pool,
        uint256 citadelAmount
    );
    event CitadelDistributionToStaking(
        uint256 startTime,
        uint256 endTime,
        uint256 citadelAmount
    );
    event CitadelDistributionToLocking(
        uint256 startTime,
        uint256 endTime,
        uint256 citadelAmount,
        uint256 xCitadelAmount
    );

    /**
     * @notice Initializer
     * @dev this contract must have the rights to mint the citadel token to function correctly
     * @dev this contract is intended to be the only way citadel is minted, with the expection of the initial minting event
     * @param _gac global access control which is pinged to allow / deny access to permissioned calls by role
     * @param _citadelToken citadel token
     * @param _xCitadel staked citadel
     * @param _xCitadelLocker staked citadel locker
     * @param _supplySchedule contract that determines how much citadel to mint at a given time
     */
    function initialize(
        address _gac,
        address _citadelToken,
        address _xCitadel,
        address _xCitadelLocker,
        address _supplySchedule
    ) external initializer {
        require(_gac != address(0), "address 0 invalid");
        require(_citadelToken != address(0), "address 0 invalid");
        require(_xCitadel != address(0), "address 0 invalid");
        require(_xCitadelLocker != address(0), "address 0 invalid");
        require(_supplySchedule != address(0), "address 0 invalid");

        __GlobalAccessControlManaged_init(_gac);
        __ReentrancyGuard_init();

        citadelToken = ICitadelToken(_citadelToken);
        xCitadel = IVault(_xCitadel);
        xCitadelLocker = IStakedCitadelLocker(_xCitadelLocker);

        supplySchedule = ISupplySchedule(_supplySchedule);

        // Approve xCitadel vault for use of citadel tokens
        citadelToken.approve(_xCitadel, type(uint256).max);
        // Approve xCitadel for locker to use
        xCitadel.approve(_xCitadelLocker, type(uint256).max);
    }

    /// =======================
    /// ===== Public view =====
    /// =======================

    function getFundingPoolWeights()
        external
        view
        returns (address[] memory pools, uint256[] memory weights)
    {
        uint256 numPools = fundingPools.length();
        pools = new address[](numPools);
        weights = new uint256[](numPools);

        for (uint256 i = 0; i < numPools; i++) {
            address pool = fundingPools.at(i);
            uint256 weight = fundingPoolWeights[pool];

            pools[i] = pool;
            weights[i] = weight;
        }
    }

    /// ==========================================
    /// ===== Permissioned Calls: Policy Ops =====
    /// ==========================================

    /**
     * @notice Update the state of citadel emissions by minting and distributing citadel tokens according to the emission schedule and proportional splits between destinations (e.g. funding pools, stakers, lockers)
     * @dev In theory this call should be permissionless, and after sufficient security analysis this may be changed to be the case
     */
    function mintAndDistribute()
        external
        onlyRole(POLICY_OPERATIONS_ROLE)
        gacPausable
        nonReentrant
    {
        uint256 mintable = supplySchedule.getMintable(
            lastMintTimestamp
        );
        citadelToken.mint(address(this), mintable);

        uint256 lockingAmount = 0;
        uint256 stakingAmount = 0;
        uint256 fundingAmount = 0;

        if (lockingBps != 0) {
            lockingAmount = mintable * lockingBps / MAX_BPS;
            uint256 beforeAmount = xCitadel.balanceOf(
                address(this)
            );

            IVault(xCitadel).deposit(lockingAmount);

            uint256 afterAmount = xCitadel.balanceOf(
                address(this)
            );

            uint256 xCitadelToLockers = afterAmount - beforeAmount;

            xCitadelLocker.notifyRewardAmount(address(xCitadel), xCitadelToLockers);
            emit CitadelDistributionToLocking(
                lastMintTimestamp,
                block.timestamp,
                lockingAmount,
                xCitadelToLockers
            );
        }

        if (stakingBps != 0) {
            stakingAmount = mintable * stakingBps / MAX_BPS;

            citadelToken.transfer(address(xCitadel), stakingAmount);
            emit CitadelDistributionToStaking(
                lastMintTimestamp,
                block.timestamp,
                stakingAmount
            );
        }

        if (fundingBps != 0) {
            fundingAmount = mintable * fundingBps / MAX_BPS;

            _transferToFundingPools(fundingAmount);
            emit CitadelDistributionToFunding(
                lastMintTimestamp,
                block.timestamp,
                fundingAmount
            );
        }

        emit CitadelDistribution(fundingAmount, stakingAmount, lockingAmount);

        lastMintTimestamp = block.timestamp;
    }

    /**
     * @notice Set the funding weight for a given address.
     * @dev If the pool does not exist and is assigned a weight
     * @dev Setting the funding pool weight to 0 for an existing pool will delete it from the set
     * @param _pool Address of funding pool contract to add
     * @param _weight Weight to give to pool. Must be between 0 and 10000, inclusive
     */
    function setFundingPoolWeight(address _pool, uint256 _weight)
        external
        onlyRole(POLICY_OPERATIONS_ROLE)
        gacPausable
        nonReentrant
    {
        require(
            address(_pool) != address(0),
            "CitadelMinter: address(0) check"
        );

        bool poolExists = fundingPools.contains(_pool);
        // Remove existing pool on 0 weight
        if (_weight == 0 && poolExists) {
            fundingPoolWeights[_pool] = 0;
            totalFundingPoolWeight =
                totalFundingPoolWeight -
                fundingPoolWeights[_pool];
            _removeFundingPool(_pool);

            emit FundingPoolWeightSet(_pool, _weight, totalFundingPoolWeight);
        } else if (_weight > 0) {
            // Add new pool or modify existing pool
            require(_weight <= 10000, "exceed max funding pool weight");
            if (!poolExists) {
                _addFundingPool(_pool);
            }
            uint256 _newTotalWeight = totalFundingPoolWeight;
            _newTotalWeight = _newTotalWeight - fundingPoolWeights[_pool];
            fundingPoolWeights[_pool] = _weight;
            _newTotalWeight = _newTotalWeight + _weight;
            totalFundingPoolWeight = _newTotalWeight;

            emit FundingPoolWeightSet(_pool, _weight, _newTotalWeight);
        }
    }

    /**
     * @notice Set the proportions of newly minted citadel to go to funding pools, stakers, and lockers on mintAndDistribute() calls
     * @dev This is decided according to the treasury / marketcap logic outlined in the tokenomics, and is intended to be automated on-chain when safe
     * @dev Sum of basis point values supplied must exactly equal 10000 (100%)
     * @param _fundingBps Percentage of newly minted citadel to be allocated to funding pools, in basis points
     * @param _stakingBps Percentage of newly minted citadel to be allocated to stakers as auto-compounding xCitadel rewards, in basis points
     * @param _lockingBps Percentage of newly minted citadel to be allocated to lockers as emitted xCitadel rewards, in basis points
     */
    function setCitadelDistributionSplit(
        uint256 _fundingBps,
        uint256 _stakingBps,
        uint256 _lockingBps
    ) external onlyRole(POLICY_OPERATIONS_ROLE) gacPausable nonReentrant {
        require(
            _fundingBps + _stakingBps + _lockingBps == MAX_BPS,
            "CitadelMinter: Sum of propvalues must be 10000 bps"
        );
        fundingBps = _fundingBps;
        stakingBps = _stakingBps;
        lockingBps = _lockingBps;

        emit CitadelDistributionSplitSet(_fundingBps, _stakingBps, _lockingBps);
    }

    /// ==========================================
    /// ===== Permissioned Calls: Governance =====
    /// ==========================================

    function initializeLastMintTimestamp()
        external
        onlyRole(CONTRACT_GOVERNANCE_ROLE)
        gacPausable
    {
        require(
            lastMintTimestamp == 0,
            "CitadelMinter: last mint timestamp already initialized"
        );
        uint256 globalStartTimestamp = ISupplySchedule(supplySchedule)
            .globalStartTimestamp();

        require(
            globalStartTimestamp >= 0,
            "CitadelMinter: supply schedule start not initialized"
        );
        lastMintTimestamp = globalStartTimestamp;
    }

    /// ==============================
    /// ===== Internal Functions =====
    /// ==============================

    // === Funding Pool Management ===
    function _transferToFundingPools(uint256 _citadelAmount) internal {
        require(fundingPools.length() > 0, "CitadelMinter: no funding pools");
        for (uint256 i = 0; i < fundingPools.length(); i++) {
            address pool = fundingPools.at(i);
            uint256 weight = fundingPoolWeights[pool];

            uint256 amount = _citadelAmount * weight / totalFundingPoolWeight;

            IERC20Upgradeable(address(citadelToken)).safeTransfer(pool, amount);

            emit CitadelDistributionToFundingPool(
                lastMintTimestamp,
                block.timestamp,
                pool,
                amount
            );
        }
    }

    function _removeFundingPool(address _pool) internal {
        require(
            fundingPools.remove(_pool),
            "CitadelMinter: funding pool does not exist for removal"
        );
    }

    function _addFundingPool(address _pool) internal {
        require(fundingPools.add(_pool), "CitadelMinter: funding pool already exists");
    }
}
