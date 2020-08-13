pragma solidity ^0.5.16;

// Inheritance
import "./Owned.sol";
import "./SelfDestructible.sol";
import "./MixinResolver.sol";
import "./MixinSystemSettings.sol";
import "./interfaces/IExchangeRates.sol";

// Libraries
import "./SafeDecimalMath.sol";

// Internal references
// AggregatorInterface from Chainlink represents a decentralized pricing network for a single currency key
import "@chainlink/contracts-0.0.9/src/v0.5/interfaces/AggregatorInterface.sol";
// FlagsInterface from Chainlink addresses SIP-76
import "@chainlink/contracts-0.0.9/src/v0.5/interfaces/FlagsInterface.sol";


// https://docs.synthetix.io/contracts/source/contracts/ExchangeRates
contract ExchangeRates is Owned, SelfDestructible, MixinResolver, MixinSystemSettings, IExchangeRates {
    using SafeMath for uint;
    using SafeDecimalMath for uint;

    struct RateAndUpdatedTime {
        uint216 rate;
        uint40 time;
    }

    // Exchange rates and update times stored by currency code, e.g. 'SNX', or 'sUSD'
    mapping(bytes32 => mapping(uint => RateAndUpdatedTime)) private _rates;

    // The address of the oracle which pushes rate updates to this contract
    address public oracle;

    // Decentralized oracle networks that feed into pricing aggregators
    mapping(bytes32 => AggregatorInterface) public aggregators;

    // List of aggregator keys for convenient iteration
    bytes32[] public aggregatorKeys;

    // Do not allow the oracle to submit times any further forward into the future than this constant.
    uint private constant ORACLE_FUTURE_LIMIT = 10 minutes;

    int private constant AGGREGATOR_RATE_MULTIPLIER = 1e10;

    // For inverted prices, keep a mapping of their entry, limits and frozen status
    struct InversePricing {
        uint entryPoint;
        uint upperLimit;
        uint lowerLimit;
        bool frozenAtUpperLimit;
        bool frozenAtLowerLimit;
    }
    mapping(bytes32 => InversePricing) public inversePricing;
    bytes32[] public invertedKeys;

    mapping(bytes32 => uint) public currentRoundForRate;

    bytes32[24] private addressesToCache = [bytes32(0)];

    //
    // ========== CONSTRUCTOR ==========

    constructor(
        address _owner,
        address _oracle,
        address _resolver,
        bytes32[] memory _currencyKeys,
        uint[] memory _newRates
    ) public Owned(_owner) SelfDestructible() MixinResolver(_resolver, addressesToCache) MixinSystemSettings() {
        require(_currencyKeys.length == _newRates.length, "Currency key length and rate length must match.");

        oracle = _oracle;

        // The sUSD rate is always 1 and is never stale.
        _setRate("sUSD", SafeDecimalMath.unit(), now);

        internalUpdateRates(_currencyKeys, _newRates, now);
    }

    /* ========== SETTERS ========== */

    function setOracle(address _oracle) external onlyOwner {
        oracle = _oracle;
        emit OracleUpdated(oracle);
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function updateRates(
        bytes32[] calldata currencyKeys,
        uint[] calldata newRates,
        uint timeSent
    ) external onlyOracle returns (bool) {
        return internalUpdateRates(currencyKeys, newRates, timeSent);
    }

    function deleteRate(bytes32 currencyKey) external onlyOracle {
        require(_getRate(currencyKey) > 0, "Rate is zero");

        delete _rates[currencyKey][currentRoundForRate[currencyKey]];

        currentRoundForRate[currencyKey]--;

        emit RateDeleted(currencyKey);
    }

    function setInversePricing(
        bytes32 currencyKey,
        uint entryPoint,
        uint upperLimit,
        uint lowerLimit,
        bool freeze,
        bool freezeAtUpperLimit
    ) external onlyOwner {
        // 0 < lowerLimit < entryPoint => 0 < entryPoint
        require(lowerLimit > 0, "lowerLimit must be above 0");
        require(upperLimit > entryPoint, "upperLimit must be above the entryPoint");
        require(upperLimit < entryPoint.mul(2), "upperLimit must be less than double entryPoint");
        require(lowerLimit < entryPoint, "lowerLimit must be below the entryPoint");

        if (inversePricing[currencyKey].entryPoint <= 0) {
            // then we are adding a new inverse pricing, so add this
            invertedKeys.push(currencyKey);
        }
        inversePricing[currencyKey].entryPoint = entryPoint;
        inversePricing[currencyKey].upperLimit = upperLimit;
        inversePricing[currencyKey].lowerLimit = lowerLimit;
        if (freeze) {
            // When indicating to freeze, we need to know the rate to freeze it at - either upper or lower
            // this is useful in situations where ExchangeRates is updated and there are existing inverted
            // rates already frozen in the current contract that need persisting across the upgrade

            inversePricing[currencyKey].frozenAtUpperLimit = freezeAtUpperLimit;
            inversePricing[currencyKey].frozenAtLowerLimit = !freezeAtUpperLimit;
            emit InversePriceFrozen(currencyKey, freezeAtUpperLimit ? upperLimit : lowerLimit, msg.sender);
        }

        emit InversePriceConfigured(currencyKey, entryPoint, upperLimit, lowerLimit);
    }

    function removeInversePricing(bytes32 currencyKey) external onlyOwner {
        require(inversePricing[currencyKey].entryPoint > 0, "No inverted price exists");

        inversePricing[currencyKey].entryPoint = 0;
        inversePricing[currencyKey].upperLimit = 0;
        inversePricing[currencyKey].lowerLimit = 0;
        inversePricing[currencyKey].frozenAtUpperLimit = false;
        inversePricing[currencyKey].frozenAtLowerLimit = false;

        // now remove inverted key from array
        bool wasRemoved = removeFromArray(currencyKey, invertedKeys);

        if (wasRemoved) {
            emit InversePriceConfigured(currencyKey, 0, 0, 0);
        }
    }

    function addAggregator(bytes32 currencyKey, address aggregatorAddress) external onlyOwner {
        AggregatorInterface aggregator = AggregatorInterface(aggregatorAddress);
        // This check tries to make sure that a valid aggregator is being added.
        // It checks if the aggregator is an existing smart contract that has implemented `latestTimestamp` function.
        require(aggregator.latestTimestamp() >= 0, "Given Aggregator is invalid");
        if (address(aggregators[currencyKey]) == address(0)) {
            aggregatorKeys.push(currencyKey);
        }
        aggregators[currencyKey] = aggregator;
        emit AggregatorAdded(currencyKey, address(aggregator));
    }

    function removeAggregator(bytes32 currencyKey) external onlyOwner {
        address aggregator = address(aggregators[currencyKey]);
        require(aggregator != address(0), "No aggregator exists for key");
        delete aggregators[currencyKey];

        bool wasRemoved = removeFromArray(currencyKey, aggregatorKeys);

        if (wasRemoved) {
            emit AggregatorRemoved(currencyKey, aggregator);
        }
    }

    // Public keeper function to freeze a synth that is out of bounds
    function freezeRate(bytes32 currencyKey) external {
        InversePricing memory inverse = inversePricing[currencyKey];
        require(inverse.entryPoint > 0, "Cannot freeze non-inverse rate");
        require(!inverse.frozenAtUpperLimit && !inverse.frozenAtLowerLimit, "The rate is already frozen");

        uint rate = _getRate(currencyKey);

        if (rate == inverse.upperLimit || rate == inverse.lowerLimit) {
            inverse.frozenAtUpperLimit = rate == inverse.upperLimit;
            inverse.frozenAtLowerLimit = rate == inverse.lowerLimit;
            emit InversePriceFrozen(currencyKey, rate, msg.sender);
        } else {
            revert("Rate within bounds");
        }
    }

    /* ========== VIEWS ========== */

    function rateStalePeriod() external view returns (uint) {
        return getRateStalePeriod();
    }

    function aggregatorWarningFlags() external view returns (address) {
        return getAggregatorWarningFlags();
    }

    function rateAndUpdatedTime(bytes32 currencyKey) external view returns (uint rate, uint time) {
        RateAndUpdatedTime memory rateAndTime = _getRateAndUpdatedTime(currencyKey);
        return (rateAndTime.rate, rateAndTime.time);
    }

    function getLastRoundIdBeforeElapsedSecs(
        bytes32 currencyKey,
        uint startingRoundId,
        uint startingTimestamp,
        uint timediff
    ) external view returns (uint) {
        uint roundId = startingRoundId;
        uint nextTimestamp = 0;
        while (true) {
            (, nextTimestamp) = _getRateAndTimestampAtRound(currencyKey, roundId + 1);
            // if there's no new round, then the previous roundId was the latest
            if (nextTimestamp == 0 || nextTimestamp > startingTimestamp + timediff) {
                return roundId;
            }
            roundId++;
        }
        return roundId;
    }

    function getCurrentRoundId(bytes32 currencyKey) external view returns (uint) {
        return _getCurrentRoundId(currencyKey);
    }

    function effectiveValueAtRound(
        bytes32 sourceCurrencyKey,
        uint sourceAmount,
        bytes32 destinationCurrencyKey,
        uint roundIdForSrc,
        uint roundIdForDest
    ) external view returns (uint value) {
        // If there's no change in the currency, then just return the amount they gave us
        if (sourceCurrencyKey == destinationCurrencyKey) return sourceAmount;

        (uint srcRate, ) = _getRateAndTimestampAtRound(sourceCurrencyKey, roundIdForSrc);
        (uint destRate, ) = _getRateAndTimestampAtRound(destinationCurrencyKey, roundIdForDest);
        // Calculate the effective value by going from source -> USD -> destination
        value = sourceAmount.multiplyDecimalRound(srcRate).divideDecimalRound(destRate);
    }

    function rateAndTimestampAtRound(bytes32 currencyKey, uint roundId) external view returns (uint rate, uint time) {
        return _getRateAndTimestampAtRound(currencyKey, roundId);
    }

    function lastRateUpdateTimes(bytes32 currencyKey) external view returns (uint256) {
        return _getUpdatedTime(currencyKey);
    }

    function lastRateUpdateTimesForCurrencies(bytes32[] calldata currencyKeys) external view returns (uint[] memory) {
        uint[] memory lastUpdateTimes = new uint[](currencyKeys.length);

        for (uint i = 0; i < currencyKeys.length; i++) {
            lastUpdateTimes[i] = _getUpdatedTime(currencyKeys[i]);
        }

        return lastUpdateTimes;
    }

    function effectiveValue(
        bytes32 sourceCurrencyKey,
        uint sourceAmount,
        bytes32 destinationCurrencyKey
    ) external view returns (uint value) {
        (value, , ) = _effectiveValueAndRates(sourceCurrencyKey, sourceAmount, destinationCurrencyKey);
    }

    function effectiveValueAndRates(
        bytes32 sourceCurrencyKey,
        uint sourceAmount,
        bytes32 destinationCurrencyKey
    )
        external
        view
        returns (
            uint value,
            uint sourceRate,
            uint destinationRate
        )
    {
        return _effectiveValueAndRates(sourceCurrencyKey, sourceAmount, destinationCurrencyKey);
    }

    function rateForCurrency(bytes32 currencyKey) external view returns (uint) {
        return _getRateAndUpdatedTime(currencyKey).rate;
    }

    function ratesAndUpdatedTimeForCurrencyLastNRounds(bytes32 currencyKey, uint numRounds)
        external
        view
        returns (uint[] memory rates, uint[] memory times)
    {
        rates = new uint[](numRounds);
        times = new uint[](numRounds);

        uint roundId = _getCurrentRoundId(currencyKey);
        for (uint i = 0; i < numRounds; i++) {
            (rates[i], times[i]) = _getRateAndTimestampAtRound(currencyKey, roundId);
            if (roundId == 0) {
                // if we hit the last round, then return what we have
                return (rates, times);
            } else {
                roundId--;
            }
        }
    }

    function ratesForCurrencies(bytes32[] calldata currencyKeys) external view returns (uint[] memory) {
        uint[] memory _localRates = new uint[](currencyKeys.length);

        for (uint i = 0; i < currencyKeys.length; i++) {
            _localRates[i] = _getRate(currencyKeys[i]);
        }

        return _localRates;
    }

    function ratesAndInvalidForCurrencies(bytes32[] calldata currencyKeys)
        external
        view
        returns (uint[] memory rates, bool anyRateInvalid)
    {
        rates = new uint[](currencyKeys.length);

        uint256 _rateStalePeriod = getRateStalePeriod();

        // fetch all flags at once
        bool[] memory flagList = getFlagsForRates(currencyKeys);

        for (uint i = 0; i < currencyKeys.length; i++) {
            // do one lookup of the rate & time to minimize gas
            RateAndUpdatedTime memory rateEntry = _getRateAndUpdatedTime(currencyKeys[i]);
            rates[i] = rateEntry.rate;
            if (!anyRateInvalid && currencyKeys[i] != "sUSD") {
                anyRateInvalid = flagList[i] || _rateIsStaleWithTime(_rateStalePeriod, rateEntry.time);
            }
        }
    }

    function rateIsStale(bytes32 currencyKey) external view returns (bool) {
        return _rateIsStale(currencyKey, getRateStalePeriod());
    }

    function rateIsFrozen(bytes32 currencyKey) external view returns (bool) {
        return _rateIsFrozen(currencyKey);
    }

    function rateIsInvalid(bytes32 currencyKey) external view returns (bool) {
        return
            _rateIsStale(currencyKey, getRateStalePeriod()) ||
            _rateIsFlagged(currencyKey, FlagsInterface(getAggregatorWarningFlags()));
    }

    function rateIsFlagged(bytes32 currencyKey) external view returns (bool) {
        return _rateIsFlagged(currencyKey, FlagsInterface(getAggregatorWarningFlags()));
    }

    function anyRateIsInvalid(bytes32[] calldata currencyKeys) external view returns (bool) {
        // Loop through each key and check whether the data point is stale.

        uint256 _rateStalePeriod = getRateStalePeriod();
        bool[] memory flagList = getFlagsForRates(currencyKeys);

        for (uint i = 0; i < currencyKeys.length; i++) {
            if (flagList[i] || _rateIsStale(currencyKeys[i], _rateStalePeriod)) {
                return true;
            }
        }

        return false;
    }

    /* ========== INTERNAL FUNCTIONS ========== */

    function getFlagsForRates(bytes32[] memory currencyKeys) internal view returns (bool[] memory flagList) {
        FlagsInterface _flags = FlagsInterface(getAggregatorWarningFlags());

        // fetch all flags at once
        if (_flags != FlagsInterface(0)) {
            address[] memory _aggregators = new address[](currencyKeys.length);

            for (uint i = 0; i < currencyKeys.length; i++) {
                _aggregators[i] = address(aggregators[currencyKeys[i]]);
            }

            flagList = _flags.getFlags(_aggregators);
        } else {
            flagList = new bool[](currencyKeys.length);
        }
    }

    function _setRate(
        bytes32 currencyKey,
        uint256 rate,
        uint256 time
    ) internal {
        // Note: this will effectively start the rounds at 1, which matches Chainlink's Agggregators
        currentRoundForRate[currencyKey]++;

        _rates[currencyKey][currentRoundForRate[currencyKey]] = RateAndUpdatedTime({
            rate: uint216(rate),
            time: uint40(time)
        });
    }

    function internalUpdateRates(
        bytes32[] memory currencyKeys,
        uint[] memory newRates,
        uint timeSent
    ) internal returns (bool) {
        require(currencyKeys.length == newRates.length, "Currency key array length must match rates array length.");
        require(timeSent < (now + ORACLE_FUTURE_LIMIT), "Time is too far into the future");

        // Loop through each key and perform update.
        for (uint i = 0; i < currencyKeys.length; i++) {
            bytes32 currencyKey = currencyKeys[i];

            // Should not set any rate to zero ever, as no asset will ever be
            // truely worthless and still valid. In this scenario, we should
            // delete the rate and remove it from the system.
            require(newRates[i] != 0, "Zero is not a valid rate, please call deleteRate instead.");
            require(currencyKey != "sUSD", "Rate of sUSD cannot be updated, it's always UNIT.");

            // We should only update the rate if it's at least the same age as the last rate we've got.
            if (timeSent < _getUpdatedTime(currencyKey)) {
                continue;
            }

            // Ok, go ahead with the update.
            _setRate(currencyKey, newRates[i], timeSent);
        }

        emit RatesUpdated(currencyKeys, newRates);

        return true;
    }

    function removeFromArray(bytes32 entry, bytes32[] storage array) internal returns (bool) {
        for (uint i = 0; i < array.length; i++) {
            if (array[i] == entry) {
                delete array[i];

                // Copy the last key into the place of the one we just deleted
                // If there's only one key, this is array[0] = array[0].
                // If we're deleting the last one, it's also a NOOP in the same way.
                array[i] = array[array.length - 1];

                // Decrease the size of the array by one.
                array.length--;

                return true;
            }
        }
        return false;
    }

    function _rateOrInverted(bytes32 currencyKey, uint rate) internal view returns (uint newRate) {
        // if an inverse mapping exists, adjust the price accordingly
        InversePricing memory inverse = inversePricing[currencyKey];
        newRate = _getInvertedRate(inverse, rate);
    }

    function _getInvertedRate(InversePricing memory inverse, uint rate) internal pure returns (uint newRate) {
        newRate = rate;
        // These cases ensures that if a price has been frozen, it stays frozen even if it returns to the bounds
        if (inverse.frozenAtUpperLimit) {
            newRate = inverse.upperLimit;
        } else if (inverse.frozenAtLowerLimit) {
            newRate = inverse.lowerLimit;
        } else if (inverse.entryPoint > 0) {
            // this ensures any rate outside the limit will never be returned
            uint doubleEntryPoint = inverse.entryPoint.mul(2);
            if (doubleEntryPoint <= rate) {
                // avoid negative numbers for unsigned ints, so set this to 0
                // which by the requirement that lowerLimit be > 0 will
                // cause this to freeze the price to the lowerLimit
                newRate = 0;
            } else {
                newRate = doubleEntryPoint.sub(rate);
            }

            // now ensure the rate is between the bounds
            if (newRate >= inverse.upperLimit) {
                newRate = inverse.upperLimit;
            } else if (newRate <= inverse.lowerLimit) {
                newRate = inverse.lowerLimit;
            }
        }
    }

    function _getRateAndUpdatedTime(bytes32 currencyKey) internal view returns (RateAndUpdatedTime memory) {
        AggregatorInterface aggregator = aggregators[currencyKey];

        if (aggregator != AggregatorInterface(0)) {
            return
                RateAndUpdatedTime({
                    rate: uint216(
                        _rateOrInverted(currencyKey, uint(aggregator.latestAnswer() * AGGREGATOR_RATE_MULTIPLIER))
                    ),
                    time: uint40(aggregator.latestTimestamp())
                });
        } else {
            RateAndUpdatedTime memory entry = _rates[currencyKey][currentRoundForRate[currencyKey]];

            return RateAndUpdatedTime({rate: uint216(_rateOrInverted(currencyKey, entry.rate)), time: entry.time});
        }
    }

    function _getCurrentRoundId(bytes32 currencyKey) internal view returns (uint) {
        AggregatorInterface aggregator = aggregators[currencyKey];

        if (aggregator != AggregatorInterface(0)) {
            return aggregator.latestRound();
        } else {
            return currentRoundForRate[currencyKey];
        }
    }

    function _getRateAndTimestampAtRound(bytes32 currencyKey, uint roundId) internal view returns (uint rate, uint time) {
        AggregatorInterface aggregator = aggregators[currencyKey];

        if (aggregator != AggregatorInterface(0)) {
            return (
                _rateOrInverted(currencyKey, uint(aggregator.getAnswer(roundId) * AGGREGATOR_RATE_MULTIPLIER)),
                aggregator.getTimestamp(roundId)
            );
        } else {
            RateAndUpdatedTime memory update = _rates[currencyKey][roundId];
            return (_rateOrInverted(currencyKey, update.rate), update.time);
        }
    }

    function _getRate(bytes32 currencyKey) internal view returns (uint256) {
        return _getRateAndUpdatedTime(currencyKey).rate;
    }

    function _getUpdatedTime(bytes32 currencyKey) internal view returns (uint256) {
        return _getRateAndUpdatedTime(currencyKey).time;
    }

    function _effectiveValueAndRates(
        bytes32 sourceCurrencyKey,
        uint sourceAmount,
        bytes32 destinationCurrencyKey
    )
        internal
        view
        returns (
            uint value,
            uint sourceRate,
            uint destinationRate
        )
    {
        sourceRate = _getRate(sourceCurrencyKey);
        // If there's no change in the currency, then just return the amount they gave us
        if (sourceCurrencyKey == destinationCurrencyKey) {
            destinationRate = sourceRate;
            value = sourceAmount;
        } else {
            // Calculate the effective value by going from source -> USD -> destination
            destinationRate = _getRate(destinationCurrencyKey);
            value = sourceAmount.multiplyDecimalRound(sourceRate).divideDecimalRound(destinationRate);
        }
    }

    function _rateIsStale(bytes32 currencyKey, uint _rateStalePeriod) internal view returns (bool) {
        // sUSD is a special case and is never stale (check before an SLOAD of getRateAndUpdatedTime)
        if (currencyKey == "sUSD") return false;

        return _rateIsStaleWithTime(_rateStalePeriod, _getUpdatedTime(currencyKey));
    }

    function _rateIsStaleWithTime(uint _rateStalePeriod, uint _time) internal view returns (bool) {
        return _time.add(_rateStalePeriod) < now;
    }

    function _rateIsFrozen(bytes32 currencyKey) internal view returns (bool) {
        InversePricing memory inverse = inversePricing[currencyKey];
        return inverse.frozenAtUpperLimit || inverse.frozenAtLowerLimit;
    }

    function _rateIsFlagged(bytes32 currencyKey, FlagsInterface flags) internal view returns (bool) {
        // sUSD is a special case and is never invalid
        if (currencyKey == "sUSD") return false;
        address aggregator = address(aggregators[currencyKey]);
        // when no aggregator or when the flags haven't been setup
        if (aggregator == address(0) || flags == FlagsInterface(0)) {
            return false;
        }
        return flags.getFlag(aggregator);
    }

    /* ========== MODIFIERS ========== */

    modifier onlyOracle {
        require(msg.sender == oracle, "Only the oracle can perform this action");
        _;
    }

    /* ========== EVENTS ========== */

    event OracleUpdated(address newOracle);
    event RatesUpdated(bytes32[] currencyKeys, uint[] newRates);
    event RateDeleted(bytes32 currencyKey);
    event InversePriceConfigured(bytes32 currencyKey, uint entryPoint, uint upperLimit, uint lowerLimit);
    event InversePriceFrozen(bytes32 currencyKey, uint rate, address initiator);
    event AggregatorAdded(bytes32 currencyKey, address aggregator);
    event AggregatorRemoved(bytes32 currencyKey, address aggregator);
}
