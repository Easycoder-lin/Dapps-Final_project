// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title Flight Delay Insurance
/// @notice Simple on-chain insurance contract: pays out if flight arrives more than CT seconds late
contract FlightDelayInsurance {
    /// @dev Who deployed the contract
    address public owner;
    /// @dev Address allowed to push flight updates (e.g. Chainlink oracle)
    address public oracle;

    /// @notice Standard statuses for an insurance
    enum Status { Active, Terminated, Claimed }
    /// @notice Claim outcome
    enum ClaimStatus { None, Paid, Denied }
    /// @notice Flight state
    enum FlightStatus { Normal, Canceled, Other }

    struct Insurance {
        address payable customer;    // wallet
        string flightCode;           // ex. "CI123"
        uint256 T1;                  // scheduled departure (UNIX)
        uint256 TP;                  // scheduled arrival (UNIX)
        uint256 TA;                  // actual arrival (UNIX), 0 if unknown
        uint256 T;                   // last check timestamp
        uint256 CT;                  // delay threshold (seconds)
        uint256 premium;             // paid in smallest unit
        uint256 claimAmount;         // payout amount
        Status status;
        ClaimStatus claimStatus;
        FlightStatus flightStatus;
    }

    /// @dev Base values (in smallest unit)
    uint256 public constant DEFAULT_CT = 4 hours;      // 14400 seconds
    uint256 public constant DEFAULT_PREMIUM = 3e17 wei;     // e.g. 300 cents
    uint256 public constant DEFAULT_CLAIM = 6e18 wei;      // e.g. 6000 cents

    uint256 private nextInsuranceId = 0;
    mapping(uint256 => Insurance) public insurances;
    mapping(address => uint256[]) public customerInsurances;

    /* ========== EVENTS ========== */
    event InsuranceCreated(uint256 indexed insuranceID, address indexed customer);
    event FlightInfoUpdated(uint256 indexed insuranceID, uint256 TA, FlightStatus flightStatus);
    event CheckedNotReady(uint256 indexed insuranceID);
    event TerminatedNoClaim(uint256 indexed insuranceID);
    event TerminatedNoData(uint256 indexed insuranceID);
    event CheckedAwaitData(uint256 indexed insuranceID);
    event TerminatedOnTime(uint256 indexed insuranceID);
    event ClaimPaid(uint256 indexed insuranceID, uint256 amount);

    /* ========== MODIFIERS ========== */
    modifier onlyOwner() {
        require(msg.sender == owner, "Owner only");
        _;
    }
    modifier onlyOracle() {
        require(msg.sender == oracle, "Oracle only");
        _;
    }
    modifier onlyOracleOrOwner() {
        require(msg.sender == oracle || msg.sender == owner, "Not authorized");
        _;
    }

    constructor(address _oracle) {
        owner = msg.sender;
        oracle = _oracle;
    }

    /// @notice Change the oracle address
    function setOracle(address _oracle) external onlyOwner {
        oracle = _oracle;
    }

    /// @notice Buy a new insurance
    /// @param flightCode Two letters + 1–4 digits, validated off-chain
    /// @param T1 Scheduled departure (UNIX timestamp)
    /// @param TP Scheduled arrival (UNIX timestamp)
    /// @return insuranceID The ID assigned
    function createInsurance(
        string calldata flightCode,
        uint256 T1,
        uint256 TP
    )
        external
        payable
        returns (uint256 insuranceID)
    {
        require(TP > T1, "TP must be after T1");
        require(msg.value == DEFAULT_PREMIUM, "Incorrect premium sent");

        insuranceID = nextInsuranceId++;
        Insurance storage ins = insurances[insuranceID];
        ins.customer = payable(msg.sender);
        ins.flightCode = flightCode;
        ins.T1 = T1;
        ins.TP = TP;
        ins.TA = 0;
        ins.T = block.timestamp;
        ins.CT = DEFAULT_CT;
        ins.premium = DEFAULT_PREMIUM;
        ins.claimAmount = DEFAULT_CLAIM;
        ins.status = Status.Active;
        ins.claimStatus = ClaimStatus.None;
        ins.flightStatus = FlightStatus.Normal;

        customerInsurances[msg.sender].push(insuranceID);
        emit InsuranceCreated(insuranceID, msg.sender);
    }

    /// @notice Update actual arrival and flight status (via oracle)
    function updateFlightInfo(
        uint256 insuranceID,
        uint256 TA,
        FlightStatus flightStatus
    )
        external
        onlyOracleOrOwner
    {
        Insurance storage ins = insurances[insuranceID];
        require(ins.status == Status.Active, "Insurance not active");

        ins.TA = TA;
        ins.flightStatus = flightStatus;
        emit FlightInfoUpdated(insuranceID, TA, flightStatus);
    }

    /// @notice Check conditions and optionally pay out
    function checkAndClaim(uint256 insuranceID) external payable onlyOwner{
        Insurance storage ins = insurances[insuranceID];
        require(ins.status == Status.Active, "Insurance not active");

        // If still before claim window:
        if (block.timestamp < ins.TP + ins.CT) {
            ins.T = block.timestamp;
            emit CheckedNotReady(insuranceID);
            return;
        }

        // Flight cancelled:
        if (ins.flightStatus == FlightStatus.Canceled) {
            ins.status = Status.Terminated;
            ins.claimStatus = ClaimStatus.Denied;
            emit TerminatedNoClaim(insuranceID);
            return;
        }

        // No TA after 72h → assume no data:
        if (ins.TA == 0 && block.timestamp >= ins.TP + 72 hours) {
            ins.status = Status.Terminated;
            ins.claimStatus = ClaimStatus.Denied;
            ins.flightStatus = FlightStatus.Other;
            emit TerminatedNoData(insuranceID);
            return;
        }

        // Still waiting for TA:
        if (ins.TA == 0) {
            ins.T = block.timestamp;
            emit CheckedAwaitData(insuranceID);
            return;
        }

        // Have TA → on-time:
        if (ins.TA <= ins.TP + ins.CT) {
            ins.status = Status.Terminated;
            ins.claimStatus = ClaimStatus.Denied;
            emit TerminatedOnTime(insuranceID);
        } else {
            // Late → pay out
            uint256 payout = ins.claimAmount;
            ins.status = Status.Claimed;
            ins.claimStatus = ClaimStatus.Paid;
            ins.customer.transfer(payout);
            emit ClaimPaid(insuranceID, payout);
        }
    }

    /* ========== VIEW HELPERS ========== */

    /// @notice Get list of insurance IDs for a customer
    function getInsurancesByCustomer(address customer)
        external
        view
        returns (uint256[] memory)
    {
        return customerInsurances[customer];
    }

    /// @notice Fallback to receive premiums
    receive() external payable {}
    fallback() external payable {}

    // withdraw smart contract balance
    function withdraw() external payable onlyOwner{
        (bool withdrawSuccess,) = payable(msg.sender).call{value: address(this).balance}("");
        require(withdrawSuccess, "Withdraw Failed !");
    }
}
