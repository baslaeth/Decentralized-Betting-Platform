// SPDX-License-Identifier: GPL-

pragma solidity >=0.7.0 <0.9.0;

enum Outcome{
    Against,    //0
    For,        //1
    Undecided   //2
}

struct Bet {
    uint amount;
    Outcome prediction;
}

contract BettingEvent{

    //wether betting event has been approved by auditor or not
    bool approved;

    //contract auditor. should be same as BettingPool audit
    address private audit = 0xcBE5B8684c7c81CFcDCb3504410B18fB5b306223;

    //author who deploys the betting event sc
    address eventAuthor;

    //bet pool address. only auditor can set
    address payable private betPoolAddress;
    //betpool instance
    BetPool private betPool;

    string eventDescription;
    Outcome result;

    uint bettorsForCount;
    uint bettorsAgainstCount;

    mapping(address => Bet) public bets;        //map of bettors and their bets
    mapping(Outcome => uint) public totalBets;  //total crypto betted in either of the outcomes

    event BetsLogger(string _message, Bet _bet);
    event BetPoolLogger(string _message, address _betPoolAddress, BetPool betpool);
    event OutcomeLog(string _message, Outcome _outcome);
    event CryptoLogger(string _description, uint _amount);
    event SuccessLogger(string, bool);
    event Winners(string _msg, uint _winnersCount);

    modifier AuditOnly{
        require(msg.sender == audit, "Only the auditor can access this function");
        _;
    }

    modifier BettingOver{
        require(result == Outcome.Undecided, "Betting period is over");
        _;
    }

    modifier Approved{
        require(approved, "contract has not been approved yet, or has been rejected");
        _;
    }

    modifier onlyOwner{
        require(msg.sender == eventAuthor, "");
        _;
    }

    constructor(string memory description) {

        approved = false;

        eventAuthor = msg.sender;

        eventDescription = description;
        result = Outcome.Undecided;

        bettorsForCount = 0;
        bettorsAgainstCount = 0;
    }

    // fallback() and receive() automatically bets on FOR

    fallback() external payable{
        Bet memory bet = Bet({
            amount: msg.value,
            prediction: Outcome.For
        });
        
        emit BetsLogger("fallback() bet", bet);

        bets[msg.sender] = bet;
    }

    receive() external payable BettingOver{
        Bet memory bet = Bet({
            amount: msg.value,
            prediction: Outcome.For
        });

        emit BetsLogger("receive() bet", bet);

        bets[msg.sender] = bet;
    }

    function projectSubmitted(string memory _codeFileHash, string memory _topicName, string memory _authorName, address _sendHashTo) external onlyOwner{
        (bool success, ) = _sendHashTo.call{value: 0, gas: 23000}
        (abi.encodeWithSignature("receiveProjectData(string, string, string)", _codeFileHash, _topicName, _authorName));
        require(success, "project submission failed");
    }

    function isProjectSubmitted(address _submissionAddress) public payable returns(bool){
        (bool success, bytes memory data) = _submissionAddress.call{value: 0, gas: 23000}(abi.encodeWithSignature("isProjectReceived()"));
        require(success, "check failed");
        return abi.decode(data, (bool));
    }

    function init(address payable _betPoolAddress) public AuditOnly{
        approved = true;
        betPoolAddress = _betPoolAddress;
        betPool = BetPool(betPoolAddress);

        emit BetPoolLogger("BetPool set", betPoolAddress, betPool);
    }

    function setResult(Outcome _outcome) public AuditOnly Approved{
        require(result == Outcome.Undecided, "Result has already been set");

        uint winnersCount = 0;

        if(_outcome == Outcome.For){
            winnersCount = bettorsForCount;
        }else{
            winnersCount = bettorsAgainstCount;
        }

        emit Winners("Winner count", winnersCount);

        result = _outcome;

        betPool.resultHandler(msg.sender, winnersCount, address(this));

        emit OutcomeLog("result has been set", result);
    }

    function placeBet(Outcome prediction) public payable Approved BettingOver{

        require(msg.value > 0, "Bet amount must be greater than 0");
        require(prediction != Outcome.Undecided, "Bet should be placed on either For or Against");

        if(prediction == Outcome.For){
            bettorsForCount++;
        }else{
            bettorsAgainstCount++;
        }

        Bet memory bet = Bet({
            amount: msg.value,
            prediction: prediction
        });

        emit BetsLogger("Bet placed", bet);

        bets[msg.sender] = bet; //map bettor address to Bet
        totalBets[prediction] += msg.value; //increment total bets and map to prediction

        
        (bool success, ) = betPoolAddress.call{value: msg.value}(
            abi.encodeWithSignature("updateBet(uint256, uint8)", msg.value, uint8(prediction))
        );

        emit SuccessLogger("betPool.call success value", success);

        require(success, "Bet could not be placed - faild to transfer");
    }

    function claimWinnings() public payable Approved{
        require(result != Outcome.Undecided, "Result must be set before claiming winnings");

        Bet memory _bet = bets[msg.sender]; //get bettors betting info

        emit BetsLogger("claiming address bet:", _bet);

        require(_bet.amount > 0, "No bet placed");
        require(_bet.prediction == result, "Bet was not successful");


        uint totalBettedCrypto = totalBets[Outcome.For] + totalBets[Outcome.Against];
        emit CryptoLogger("total betted crypto", totalBettedCrypto);
        
        //total betted crypto times bettors betted amount
        //value required to determine winners percentage
        totalBettedCrypto *= _bet.amount;

        //adjust commission cost. remainder will be sent for commission (should be improved!!!)
        //total amount - remainder
        uint256 commission = totalBettedCrypto % totalBets[result];
        uint256 winnerPayment = totalBettedCrypto - commission;
        winnerPayment /= totalBets[result]; //clean division

        emit CryptoLogger("commision fee", commission);
        emit CryptoLogger("winners total money", winnerPayment);

        //send winnings. address, commission fee, winners payment
        betPool.sendWinning(payable (msg.sender), commission, winnerPayment-1000000);
    }
}

contract BetPool{


    uint public winnersCount; //count of total winners

    //auditor, privileged user that can audit the contract
    address private audit = 0xcBE5B8684c7c81CFcDCb3504410B18fB5b306223;

    address payable private commissionAddress;  //account where commision crypto is sent to
    address private bettingEvent;


    event CryptoLogger(string _message, uint256 _amount);
    event AddressMessage(string _message, address _address);
    event Winners(string _msg, uint winnerCount);
    event Message(string _message);

    modifier AuditOnly{
        require(msg.sender == audit, "Only the auditor can access this function");
        _;
    }

    modifier WinnersPaid(){
        require(winnersCount == 0, "Winners are not fully paid, can't send remainig eth to commission");
        _;
    }

    modifier ReadyToClaim{
        require(bettingEvent != 0x0000000000000000000000000000000000000000, "Result is not yet been set.");
        _;
    } 

    //contract should be deployed by auditor with it's own address.
    constructor() AuditOnly {}

    fallback() external payable {}
    receive() external payable {}

    function changeAuditor(address newAuditor) public payable AuditOnly{
        audit = newAuditor;
        emit AddressMessage("auditor changed", audit);
    }

    function setCommissionAddress(address payable _address) public payable AuditOnly{
        commissionAddress = _address;
        emit AddressMessage("commission address changed", commissionAddress);
    }

    function resultHandler(address _sender, uint _winners, address _bettingEvent) public payable {

        require(_sender == audit, "only auditor can call this funciton");

        winnersCount = _winners;
        bettingEvent = _bettingEvent;

        emit Winners("total winners in BetPool", winnersCount);
    }

    function sendCommission(address payable _commisionAddress) public payable WinnersPaid AuditOnly{
        uint256 balance = address(this).balance;
        require(balance > 0, "Pool balance is empty");

        _commisionAddress.transfer(balance);
        emit Message("commision sent");
    }

    function sendWinning(address payable _winner, uint256 _commision, uint256 _winnerAmount) public payable ReadyToClaim{

        bool success = commissionAddress.send(_commision);

        if(!success){
            emit CryptoLogger("unable to send commission, could be that commission address is not specified! commision fee was", _commision);
        }else{
            emit CryptoLogger("commission fee sent successfully! commision fee was", _commision);
        }

        _winner.transfer(_winnerAmount);
        winnersCount--;
        emit Message("winning claimed");
    }
}