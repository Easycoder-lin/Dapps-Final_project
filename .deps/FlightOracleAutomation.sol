// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @title Flight Automation Oracle
/// @notice Fetches real flight data and calls FlightDelayInsurance.updateFlightInfo
import "@chainlink/contracts/src/v0.8/automation/interfaces/AutomationCompatibleInterface.sol";
import "@chainlink/contracts/src/v0.8/functions/v1_0_0/FunctionsClient.sol";
import "@chainlink/contracts/src/v0.8/functions/v1_0_0/libraries/FunctionsRequest.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

interface IFlightDelayInsurance {
    function updateFlightInfo(uint256 insuranceID, uint256 TA, uint8 flightStatus) external;
}

contract FlightAutomationOracle is AutomationCompatibleInterface, FunctionsClient {
    using FunctionsRequest for FunctionsRequest.Request;
    using Strings for uint256;

    // Address of your original insurance contract
    address public immutable flightContract;
    // Time between updates
    uint256 public interval;
    uint256 public lastTimeStamp;
    bytes32 public latestRequestId;
    mapping(bytes32 => uint256) private requestToInsurance;

    event OracleRequestSent(bytes32 indexed requestId, uint256 insuranceID);
    event FlightInfoReturned(bytes32 indexed requestId, uint256 insuranceID, uint256 TA, uint8 flightStatus);

    constructor(
        address _flightContract,
        address router,
        uint256 _interval
    ) FunctionsClient(router) {
        flightContract = _flightContract;
        interval = _interval;
        lastTimeStamp = block.timestamp;
    }

    /**
     * @notice Called by Chainlink Automation to see if upkeep is needed
     */
    function checkUpkeep(bytes calldata) external view override returns (bool upkeepNeeded, bytes memory) {
        upkeepNeeded = (block.timestamp - lastTimeStamp) > interval;
    }

    /**
     * @notice Called by Chainlink Automation to perform the data request
     */
    function performUpkeep(bytes calldata) external override {
        if ((block.timestamp - lastTimeStamp) > interval) {
            lastTimeStamp = block.timestamp;
            // Change '0' to any insurance ID you want to update
            _requestFlightData(0);
        }
    }

    /**
     * @dev Builds and sends a Chainlink Functions request
     * @param insuranceID The insurance to update
     */
    function _requestFlightData(uint256 insuranceID) internal {
        FunctionsRequest.Request memory req;
        req.initializeRequestForInlineJavaScript(
            "const apiKey = args[0];\n"
            "const insuranceID = args[1];\n"
            "const flightCode = '<FLIGHT_CODE>'; // replace or fetch dynamically\n"
            "const url = `http://api.aviationstack.com/v1/flights?access_key=${apiKey}&flight_iata=${flightCode}`;\n"
            "const resp = await Functions.makeHttpRequest({url});\n"
            "if (resp.error) throw Error('API error');\n"
            "const data = resp.data.data[0];\n"
            "const TA = Math.floor(Date.parse(data.arrival.estimated) / 1000);\n"
            "const statusMap = { scheduled:0, active:1, landed:2, cancelled:3 };\n"
            "const fs = statusMap[data.flight_status] || 3;\n"
            "return [TA.toString(), fs.toString(), insuranceID.toString()];"
        );

        // Build dynamic args array
        string[] memory args = new string[](2);
        args[0] = "<API_KEY>";
        args[1] = insuranceID.toString();
        req.setArgs(args);

        // Send request: subscriptionId = 1, gasLimit = 200000, dataVersion from FunctionsRequest
        bytes32 requestId = _sendRequest(req.encodeCBOR(), 1, 200000, FunctionsRequest.REQUEST_DATA_VERSION);
        requestToInsurance[requestId] = insuranceID;
        latestRequestId = requestId;
        emit OracleRequestSent(requestId, insuranceID);
    }

    /**
     * @notice Called by Chainlink Functions node with the response
     */
    function fulfillRequest(
        bytes32 requestId,
        bytes memory response,
        bytes memory err
    ) internal override {
        require(err.length == 0, "Oracle error");
        uint256 insuranceID = requestToInsurance[requestId];
        // decode [TA, flightStatus, insuranceID]
        (uint256 TA, uint8 fs, uint256 id) = abi.decode(response, (uint256, uint8, uint256));
        emit FlightInfoReturned(requestId, insuranceID, TA, fs);

        // Call original contract to update
        IFlightDelayInsurance(flightContract).updateFlightInfo(insuranceID, TA, fs);
    }
}