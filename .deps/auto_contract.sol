//SPDX-License-Identifier: MIT
pragma solidity ^0.8.7;

import "@chainlink/contracts/src/v0.8/interfaces/KeeperCompatibleInterface.sol";

/// @title Flight Delay Insurance
/// @notice Pays out if the flight arrives more than CT seconds late.
///         Chainlink Automation wakes the contract; an off‑chain listener reacts
///         to NeedFlightData events, calls Amadeus, then pushes the data back
///         via updateFlightInfo().
contract FlightDelayInsurance is KeeperCompatibleInterface {
    // --------------------------------------------------------------------- //
    //  Types & storage
    // --------------------------------------------------------------------- //
    address public owner;
    address public oracle;        // address allowed to push flight updates

    enum Status      { Active, Terminated, Claimed }
    enum ClaimStatus { None, Paid, Denied }
    enum FlightStatus{ Normal, Canceled, Other }

    struct Insurance {
        address payable customer;
        string   flightCode;
        uint256  T1;          // scheduled departure (unix)
        uint256  TP;          // scheduled arrival   (unix)
        uint256  TA;          // actual arrival      (unix) — 0 if unknown
        uint256  T;           // last check time
        uint256  CT;          // delay threshold
        uint256  premium;
        uint256  claimAmount;
        Status   status;
        ClaimStatus   claimStatus;
        FlightStatus  flightStatus;
    }

    uint256 public constant DEFAULT_CT     = 4 minutes;
    uint256 public constant DEFAULT_PREMIUM= 300 wei;
    uint256 public constant DEFAULT_CLAIM  = 6000 wei;

    uint256 private nextInsuranceId;
    mapping(uint256 => Insurance)        public insurances;
    mapping(address  => uint256[])       public customerInsurances;

    uint256 public lastAutomationTime;
    uint256 public constant AUTOMATION_INTERVAL = 1 hours;

    // --------------------------------------------------------------------- //
    //  Events
    // --------------------------------------------------------------------- //
    event InsuranceCreated   (uint256 indexed insuranceID, address indexed customer);
    event FlightInfoUpdated  (uint256 indexed insuranceID, uint256 TA, FlightStatus flightStatus);
    event NeedFlightData     (uint256 indexed insuranceID, string  flightCode);   // <‑‑ NEW
    event CheckedNotReady    (uint256 indexed insuranceID);
    event TerminatedNoClaim  (uint256 indexed insuranceID);
    event TerminatedNoData   (uint256 indexed insuranceID);
    event CheckedAwaitData   (uint256 indexed insuranceID);
    event TerminatedOnTime   (uint256 indexed insuranceID);
    event ClaimPaid          (uint256 indexed insuranceID, uint256 amount);

    // --------------------------------------------------------------------- //
    //  Modifiers
    // --------------------------------------------------------------------- //
    modifier onlyOwner() {
        require(msg.sender == owner, "Owner only");
        _;
    }
    modifier onlyOracleOrOwner() {
        require(msg.sender == oracle || msg.sender == owner, "Not authorised");
        _;
    }

    // --------------------------------------------------------------------- //
    //  Constructor & admin
    // --------------------------------------------------------------------- //
    constructor(address _oracle) {
        owner  = msg.sender;
        oracle = _oracle;
    }

    function setOracle(address _oracle) external onlyOwner {
        oracle = _oracle;
    }

    // --------------------------------------------------------------------- //
    //  User‑facing functions
    // --------------------------------------------------------------------- //
    function createInsurance(
        string calldata flightCode,
        uint256 T1,
        uint256 TP
    )
        external
        payable
        returns (uint256 insuranceID)
    {
        require(TP > T1,                 "TP must be after T1");
        require(msg.value == DEFAULT_PREMIUM, "Incorrect premium");

        insuranceID = nextInsuranceId++;

        Insurance storage ins = insurances[insuranceID];
        ins.customer     = payable(msg.sender);
        ins.flightCode   = flightCode;
        ins.T1           = T1;
        ins.TP           = TP;
        ins.CT           = DEFAULT_CT;
        ins.premium      = DEFAULT_PREMIUM;
        ins.claimAmount  = DEFAULT_CLAIM;
        ins.status       = Status.Active;
        ins.claimStatus  = ClaimStatus.None;
        ins.flightStatus = FlightStatus.Normal;
        ins.T            = block.timestamp;   // first touch
        // TA stays 0

        customerInsurances[msg.sender].push(insuranceID);
        emit InsuranceCreated(insuranceID, msg.sender);
    }

    /// @notice Oracle (or owner while testing) pushes real flight data
    function updateFlightInfo(
        uint256 insuranceID,
        uint256 TA,
        FlightStatus flightStatus
    )
        external
        onlyOracleOrOwner
    {
        Insurance storage ins = insurances[insuranceID];
        require(ins.status == Status.Active, "Not active");

        ins.TA          = TA;
        ins.flightStatus= flightStatus;
        emit FlightInfoUpdated(insuranceID, TA, flightStatus);
    }

    // --------------------------------------------------------------------- //
    //  Core logic — can be called directly or via performUpkeep()
    // --------------------------------------------------------------------- //
    function checkAndClaim(uint256 insuranceID) public {
        Insurance storage ins = insurances[insuranceID];
        require(ins.status == Status.Active, "Not active");

        // (1) Still before payout window
        if (block.timestamp < ins.TP + ins.CT) {
            ins.T = block.timestamp;
            emit CheckedNotReady(insuranceID);
            return;
        }

        // (2) Flight cancelled: no claim
        if (ins.flightStatus == FlightStatus.Canceled) {
            ins.status      = Status.Terminated;
            ins.claimStatus = ClaimStatus.Denied;
            emit TerminatedNoClaim(insuranceID);
            return;
        }

        // (3) No data for >72 h: terminate without claim
        if (ins.TA == 0 && block.timestamp >= ins.TP + 72 hours) {
            ins.status       = Status.Terminated;
            ins.claimStatus  = ClaimStatus.Denied;
            ins.flightStatus = FlightStatus.Other;
            emit TerminatedNoData(insuranceID);
            return;
        }

        // (4) Still awaiting data (<72 h) — trigger off‑chain fetch
        if (ins.TA == 0) {
            ins.T = block.timestamp;
            emit NeedFlightData(insuranceID, ins.flightCode);  // <‑‑ NEW
            emit CheckedAwaitData(insuranceID);
            return;
        }

        // (5) We have data: on‑time vs late
        if (ins.TA <= ins.TP + ins.CT) {
            ins.status      = Status.Terminated;
            ins.claimStatus = ClaimStatus.Denied;
            emit TerminatedOnTime(insuranceID);
        } else {
            uint256 payout  = ins.claimAmount;
            ins.status      = Status.Claimed;
            ins.claimStatus = ClaimStatus.Paid;
            ins.customer.transfer(payout);
            emit ClaimPaid(insuranceID, payout);
        }
    }

    // --------------------------------------------------------------------- //
    //  Chainlink Automation
    // --------------------------------------------------------------------- //
    function checkUpkeep(bytes calldata)
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        upkeepNeeded = (block.timestamp >= lastAutomationTime + AUTOMATION_INTERVAL);
        performData  = "";
    }

    function performUpkeep(bytes calldata) external override {
        lastAutomationTime = block.timestamp;
        // very small demo loop; for production chunk or index
        for (uint256 id = 0; id < nextInsuranceId; ++id) {
            Insurance storage ins = insurances[id];
            if (ins.status == Status.Active && block.timestamp >= ins.TP + ins.CT) {
                checkAndClaim(id);
            }
        }
    }

    // --------------------------------------------------------------------- //
    //  View helpers & admin
    // --------------------------------------------------------------------- //
    function getInsurancesByCustomer(address customer)
        external
        view
        returns (uint256[] memory)
    {
        return customerInsurances[customer];
    }

    function withdraw() external onlyOwner {
        (bool ok, ) = payable(msg.sender).call{ value: address(this).balance }("");
        require(ok, "Withdraw failed");
    }

    receive() external payable {}
    fallback() external payable {}
}
