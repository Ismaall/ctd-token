pragma solidity 0.4.15;

import './lib/zeppelin-solidity/math/SafeMath.sol';
import './PausableOnce.sol';
import './UpgradableToken.sol';
import './Withdrawable.sol';


contract UmuToken is UpgradableToken, PausableOnce, Withdrawable {

    using SafeMath for uint256;

    string public constant name = "UMU Token";
    string public constant symbol = "UMU";
    /** Number of "Atom" in 1 UMU (1 UMU = 1x10^decimals Atom) */
    uint8  public constant decimals = 18;

    /** Holder of bounty tokens */
    address public bounty;

    /** Limit (in Atom) issued, inclusive owner's and bounty shares */
    uint256 constant internal TOTAL_LIMIT = 496000000 * (10 ** uint256(decimals));
    /** Limit (in Atom) for Pre-ICO Phases A, incl. owner's and bounty shares */
    uint256 constant internal PRE_ICO_LIMIT = 99200000 * (10 ** uint256(decimals));

    /**
    * ICO Phases.
    *
    * - PreStart: tokens are not yet sold/issued
    * - PreIcoA:  new tokens sold/issued at the premium price
    * - PreIcoB:  new tokens sold/issued at the discounted price
    * - MainIco   new tokens sold/issued at the regular price
    * - AfterIco: new tokens can not be not be sold/issued any longer
    */
    enum Phases {PreStart, PreIcoA, PreIcoB, MainIco, AfterIco}

    uint64 constant internal PRE_ICO_DURATION = 30 days;
    uint64 constant internal ICO_DURATION = 80 days;

    // Main ICO rate in UMU(s) per 1 ETH:
    uint32 constant internal TO_SENDER_RATE   = 1000;
    uint32 constant internal TO_OWNER_RATE    =  200;
    uint32 constant internal TO_BOUNTY_RATE   =   40;
    // Pre-ICO Phase A rate
    uint32 constant internal TO_SENDER_RATE_A = 1150;
    uint32 constant internal TO_OWNER_RATE_A  =  230;
    uint32 constant internal TO_BOUNTY_RATE_A =   46;
    // Pre-ICO Phase B rate
    uint32 constant internal TO_SENDER_RATE_B = 1100;
    uint32 constant internal TO_OWNER_RATE_B  =  220;
    uint32 constant internal TO_BOUNTY_RATE_B =   44;

    // Award in Wei(s) to a successful initiator of a Phase shift
    uint256 constant internal PRE_OPENING_AWARD = 100 * (10 ** uint256(15));
    uint256 constant internal ICO_OPENING_AWARD = 200 * (10 ** uint256(15));
    uint256 constant internal ICO_CLOSING_AWARD = 500 * (10 ** uint256(15));

    struct Rates {
        uint32 toSender;
        uint32 toOwner;
        uint32 toBounty;
        uint32 total;
    }

    event NewTokens(uint256 amount);
    event NewPhase(Phases phase);

    // current Phase
    Phases public phase = Phases.PreStart;

    // Timestamps limiting duration of Phases, in seconds since Unix epoch.
    uint64 public preIcoOpeningTime;  // when Pre-ICO Phase A starts
    uint64 public icoOpeningTime;     // when Main ICO starts (if not sold out before)
    uint64 public closingTime;        // by when the ICO campaign finishes in any way

    /*
    * @param _preIcoOpeningTime Timestamp when the Pre-ICO (Phase A) shall start
    * msg.value MUST be at least the sum of awards
    */
    function UmuToken(uint64 _preIcoOpeningTime) onlyOwner {
        require(_preIcoOpeningTime > now);

        owner = msg.sender;
        preIcoOpeningTime = _preIcoOpeningTime;
        icoOpeningTime = preIcoOpeningTime + PRE_ICO_DURATION;
        closingTime = icoOpeningTime + ICO_DURATION;
    }

    /// @dev Fallback function delegates the request to create().
    function () payable whenIcoActive external {
        create();
    }

    function setBounty(address _bounty) onlyOwner whenNotOpened public returns (bool success) {

        require(_bounty != address(0));
        bounty = _bounty;
        return true;
    }

    function create() payable whenIcoActive whenNotPaused public returns (bool success) {
        require(msg.value > 0);

        Phases oldPhase = phase;
        uint256 weiToParticipate = msg.value;
        uint256 overpaidWei = 0;

        adjustPhaseBasedOnTime();
        Rates memory rates = getRates();
        uint256 newTokens = weiToParticipate.mul(uint256(rates.total));
        uint256 requestedSupply = totalSupply.add(newTokens);

        uint256 oversoldTokens = computeOversoldAndAdjustPhase(requestedSupply);
        if (oversoldTokens > 0) {
            overpaidWei = oversoldTokens.div(rates.total);
            weiToParticipate = msg.value.sub(overpaidWei);
            newTokens = weiToParticipate.mul(uint256(rates.total));
            requestedSupply = totalSupply.add(newTokens);
        }

        // new tokens "emission"
        totalSupply = requestedSupply;
        balances[msg.sender] = balances[msg.sender].add(weiToParticipate.mul(uint256(rates.toSender)));
        balances[owner] = balances[owner].add(weiToParticipate.mul(uint256(rates.toOwner)));
        balances[bounty] = balances[bounty].add(weiToParticipate.mul(uint256(rates.toBounty)));

        // ETH transfers
        owner.transfer(weiToParticipate);
        if (overpaidWei > 0) {
            withdrawal(msg.sender, overpaidWei);
        }
        // Logging and awarding
        NewTokens(newTokens);
        if (phase != oldPhase) {
            logShiftAndBookAward();
        }

        return true;
    }

    function returnWei() onlyOwner whenClosed public {
        owner.transfer(this.balance);
    }

    function adjustPhaseBasedOnTime() internal {

        if (now >= closingTime) {
            if (phase != Phases.AfterIco) {
                phase = Phases.AfterIco;
            }
        } else if (now >= icoOpeningTime) {
            if (phase != Phases.MainIco) {
                phase = Phases.MainIco;
            }
        } else if (now >= preIcoOpeningTime) {
            if (phase == Phases.PreStart) {
                setDefaultParamsIfNeeded();
                phase = Phases.PreIcoA;
            }
        }
    }

    function setDefaultParamsIfNeeded() internal {
        if (bounty == address(0)) {
            bounty = owner;
        }
        if (upgradeMaster == address(0)) {
            upgradeMaster = owner;
        }
        if (pauseMaster == address(0)) {
            pauseMaster = owner;
        }
    }

    function computeOversoldAndAdjustPhase(uint256 newTotalSupply) internal returns (uint256 oversoldTokens) {

        if (newTotalSupply >= TOTAL_LIMIT) {
            phase = Phases.AfterIco;
            oversoldTokens = newTotalSupply.sub(TOTAL_LIMIT);

        } else if ((phase == Phases.PreIcoA) &&
                   (newTotalSupply >= PRE_ICO_LIMIT)) {
            phase = Phases.PreIcoB;
            oversoldTokens = newTotalSupply.sub(PRE_ICO_LIMIT);

        } else {
            oversoldTokens = 0;
        }

        return oversoldTokens;
    }

    function getRates() internal returns (Rates rates) {

        if (phase == Phases.PreIcoA) {
            rates.toSender = TO_SENDER_RATE_A;
            rates.toOwner = TO_OWNER_RATE_A;
            rates.toBounty = TO_BOUNTY_RATE_A;
            rates.total = TO_SENDER_RATE_A + TO_OWNER_RATE_A + TO_BOUNTY_RATE_A;
        } else if (phase == Phases.PreIcoB) {
            rates.toSender = TO_SENDER_RATE_B;
            rates.toOwner = TO_OWNER_RATE_B;
            rates.toBounty = TO_BOUNTY_RATE_B;
            rates.total = TO_SENDER_RATE_B + TO_OWNER_RATE_B + TO_BOUNTY_RATE_B;
        } else {
            rates.toSender = TO_SENDER_RATE;
            rates.toOwner = TO_OWNER_RATE;
            rates.toBounty = TO_BOUNTY_RATE;
            rates.total = TO_SENDER_RATE + TO_OWNER_RATE + TO_BOUNTY_RATE;
        }
        return rates;
    }

    function logShiftAndBookAward() internal {
        uint256 shiftAward;

        if (phase == Phases.PreIcoA) {
            shiftAward = ICO_OPENING_AWARD;

        } else if (phase == Phases.MainIco) {
            shiftAward = PRE_OPENING_AWARD;

        } else {
            shiftAward = ICO_CLOSING_AWARD;
        }

        withdrawal(msg.sender, shiftAward);
        NewPhase(phase);
        Withdrawal(msg.sender, shiftAward);
    }

    function transfer(address _to, uint256 _value)
        whenNotPaused limitForOwner public returns (bool success)
    {
        return super.transfer(_to, _value);
    }

    function transferFrom(address _from, address _to, uint256 _value)
        whenNotPaused limitForOwner public returns (bool success)
    {
        return super.transferFrom(_from, _to, _value);
    }

    function approve(address _spender, uint256 _value)
        whenNotPaused limitForOwner public returns (bool success)
    {
        return super.approve(_spender, _value);
    }

    function increaseApproval(address _spender, uint _addedValue)
        whenNotPaused limitForOwner public returns (bool success)
    {
        return super.increaseApproval(_spender, _addedValue);
    }

    function decreaseApproval(address _spender, uint _subtractedValue)
        whenNotPaused limitForOwner public returns (bool success)
    {
        return super.decreaseApproval(_spender, _subtractedValue);
    }

    function withdraw() whenNotPaused public returns (bool success) {
        return super.withdraw();
    }

    modifier whenNotOpened() {
        require(phase == Phases.PreStart);
        _;
    }

    modifier whenClosed() {
        require(phase >= Phases.AfterIco);
        _;
    }

    modifier whenIcoActive() {
        require((phase == Phases.PreIcoA) || (phase == Phases.PreIcoB) || (phase == Phases.MainIco));
        _;
    }

    modifier limitForOwner() {
        require((msg.sender != owner) || (phase == Phases.AfterIco));
        _;
    }

}
