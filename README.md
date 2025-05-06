# DDAO-Final-Project


## Flight Delay Insurance Smart Contract Overview

This smart contract implements a **simple decentralized flight delay insurance** system on Ethereum. Users can:

* Purchase insurance for a specific flight.
* Receive a payout if the flight arrives significantly late.
* Have data updated by a trusted oracle (e.g. Chainlink).
* Be refunded based on on-chain evaluation of flight status.

[Remix demo](https://docs.google.com/presentation/d/17anx4L4A_kWIidtTais4Rj12T75dhY_wYESPzIpbIWo/edit?usp=sharing)

---

## 🔐 Roles

| Role     | Address                   | Functionality                                                     |
| -------- | ------------------------- | ----------------------------------------------------------------- |
| `owner`  | Deployer                  | Can set the oracle, withdraw funds, and trigger `checkAndClaim()` |
| `oracle` | Chainlink node or backend | Updates flight arrival info and status                            |

---

## 📄 Contract Variables

* `DEFAULT_CT`: Delay threshold for claim (4 hours).
* `DEFAULT_PREMIUM`: Fee paid by customer (0.3 ETH in wei).
* `DEFAULT_CLAIM`: Payout for valid claims (6 ETH in wei).
* `insurances`: Mapping of insurance ID to policy details.
* `customerInsurances`: Customer address to their insurance IDs.

---

## 📦 Insurance Structs

```solidity
struct Insurance {
  address payable customer;
  string flightCode;
  uint256 T1;  // Scheduled departure
  uint256 TP;  // Scheduled arrival
  uint256 TA;  // Actual arrival (0 if unknown)
  uint256 T;   // Last check timestamp
  uint256 CT;  // Delay threshold
  uint256 premium;
  uint256 claimAmount;
  Status status;
  ClaimStatus claimStatus;
  FlightStatus flightStatus;
}
```

---

## 📜 Public Functions

### ✅ `createInsurance(string flightCode, uint256 T1, uint256 TP)`

* Called by front-end when user buys a new policy.
* Requires `msg.value == DEFAULT_PREMIUM`.
* Returns: `insuranceID`.

### 📡 `updateFlightInfo(uint256 insuranceID, uint256 TA, FlightStatus flightStatus)`

* Called by oracle or owner to update actual arrival time and status.

### 🧾 `checkAndClaim(uint256 insuranceID)`

* Called by the owner to evaluate and process a claim.
* Checks flight data and time window, then:

  * Pays claim if late.
  * Denies if on-time or canceled.

### 🗂 `getInsurancesByCustomer(address customer)`

* Returns an array of insurance IDs for a specific address.

### 💰 `withdraw()`

* Owner-only: Withdraws entire contract balance to owner's address.

---

## 🧪 Sample Workflow

1. User buys insurance:

   * `createInsurance("CI123", T1, TP)` with 0.3 ETH.
2. Oracle updates flight info:

   * `updateFlightInfo(ID, TA, FlightStatus.Normal)`.
3. Owner checks for payout eligibility:

   * `checkAndClaim(ID)`.

---

## 📜 Enums for Status

```solidity
enum Status { Active, Terminated, Claimed }
enum ClaimStatus { None, Paid, Denied }
enum FlightStatus { Normal, Canceled, Other }
```

---

