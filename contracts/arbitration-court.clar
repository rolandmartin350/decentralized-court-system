;; Decentralized Arbitration Court Contract
;; Provides dispute resolution through randomly selected jurors and transparent processes

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-CASE-NOT-FOUND (err u101))
(define-constant ERR-INVALID-STATUS (err u102))
(define-constant ERR-ALREADY-VOTED (err u103))
(define-constant ERR-NOT-JUROR (err u104))
(define-constant ERR-INSUFFICIENT-STAKE (err u105))
(define-constant ERR-CASE-CLOSED (err u106))
(define-constant ERR-VOTING-ENDED (err u107))
(define-constant ERR-INVALID-AMOUNT (err u108))

;; Case status constants
(define-constant STATUS-PENDING u0)
(define-constant STATUS-ACTIVE u1)
(define-constant STATUS-VOTING u2)
(define-constant STATUS-RESOLVED u3)
(define-constant STATUS-APPEALED u4)

;; Data Variables
(define-data-var case-nonce uint u0)
(define-data-var juror-nonce uint u0)
(define-data-var min-juror-stake uint u1000000) ;; 1 STX
(define-data-var voting-period uint u1440) ;; ~10 days in blocks
(define-data-var min-jurors uint u3)

;; Data Maps

;; Cases
(define-map cases
  { case-id: uint }
  {
    plaintiff: principal,
    defendant: principal,
    description: (string-utf8 500),
    amount: uint,
    status: uint,
    filed-at: uint,
    voting-ends: uint,
    votes-for: uint,
    votes-against: uint,
    resolution: (optional (string-utf8 200))
  }
)

;; Evidence submissions
(define-map evidence
  { case-id: uint, evidence-id: uint }
  {
    submitter: principal,
    content-hash: (string-ascii 100),
    submitted-at: uint
  }
)

;; Evidence counter per case
(define-map evidence-count
  { case-id: uint }
  { count: uint }
)

;; Juror registry
(define-map jurors
  { juror: principal }
  {
    stake: uint,
    reputation: uint,
    cases-judged: uint,
    is-active: bool
  }
)

;; Case juror assignments
(define-map case-jurors
  { case-id: uint, juror: principal }
  {
    assigned-at: uint,
    has-voted: bool
  }
)

;; Votes
(define-map votes
  { case-id: uint, juror: principal }
  {
    vote: bool,
    reasoning: (optional (string-utf8 300)),
    voted-at: uint
  }
)

;; Read-only functions

(define-read-only (get-case (case-id uint))
  (map-get? cases { case-id: case-id })
)

(define-read-only (get-evidence (case-id uint) (evidence-id uint))
  (map-get? evidence { case-id: case-id, evidence-id: evidence-id })
)

(define-read-only (get-evidence-count (case-id uint))
  (default-to { count: u0 }
    (map-get? evidence-count { case-id: case-id })
  )
)

(define-read-only (get-juror (juror principal))
  (map-get? jurors { juror: juror })
)

(define-read-only (get-case-juror (case-id uint) (juror principal))
  (map-get? case-jurors { case-id: case-id, juror: juror })
)

(define-read-only (get-vote (case-id uint) (juror principal))
  (map-get? votes { case-id: case-id, juror: juror })
)

(define-read-only (get-min-stake)
  (ok (var-get min-juror-stake))
)

(define-read-only (is-case-resolved (case-id uint))
  (match (get-case case-id)
    case-data (ok (is-eq (get status case-data) STATUS-RESOLVED))
    (err ERR-CASE-NOT-FOUND)
  )
)

;; Public functions

;; Register as a juror
(define-public (register-juror (stake-amount uint))
  (begin
    (asserts! (>= stake-amount (var-get min-juror-stake)) ERR-INSUFFICIENT-STAKE)
    (map-set jurors
      { juror: tx-sender }
      {
        stake: stake-amount,
        reputation: u100,
        cases-judged: u0,
        is-active: true
      }
    )
    (ok true)
  )
)

;; File a new case
(define-public (file-case (description (string-utf8 500)) (amount uint) (defendant principal))
  (let
    (
      (new-case-id (+ (var-get case-nonce) u1))
    )
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)
    (asserts! (not (is-eq tx-sender defendant)) ERR-NOT-AUTHORIZED)
    
    (map-set cases
      { case-id: new-case-id }
      {
        plaintiff: tx-sender,
        defendant: defendant,
        description: description,
        amount: amount,
        status: STATUS-PENDING,
        filed-at: block-height,
        voting-ends: u0,
        votes-for: u0,
        votes-against: u0,
        resolution: none
      }
    )
    
    (map-set evidence-count
      { case-id: new-case-id }
      { count: u0 }
    )
    
    (var-set case-nonce new-case-id)
    (ok new-case-id)
  )
)

;; Submit evidence for a case
(define-public (submit-evidence (case-id uint) (content-hash (string-ascii 100)))
  (let
    (
      (case-data (unwrap! (get-case case-id) ERR-CASE-NOT-FOUND))
      (evidence-counter (get count (get-evidence-count case-id)))
      (new-evidence-id (+ evidence-counter u1))
    )
    (asserts! (or (is-eq tx-sender (get plaintiff case-data))
                  (is-eq tx-sender (get defendant case-data)))
              ERR-NOT-AUTHORIZED)
    (asserts! (< (get status case-data) STATUS-VOTING) ERR-INVALID-STATUS)
    
    (map-set evidence
      { case-id: case-id, evidence-id: new-evidence-id }
      {
        submitter: tx-sender,
        content-hash: content-hash,
        submitted-at: block-height
      }
    )
    
    (map-set evidence-count
      { case-id: case-id }
      { count: new-evidence-id }
    )
    
    (ok new-evidence-id)
  )
)

;; Assign jurors to a case (simplified - in production would use VRF)
(define-public (assign-juror (case-id uint) (juror principal))
  (let
    (
      (case-data (unwrap! (get-case case-id) ERR-CASE-NOT-FOUND))
      (juror-data (unwrap! (get-juror juror) ERR-NOT-JUROR))
    )
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (asserts! (is-eq (get status case-data) STATUS-PENDING) ERR-INVALID-STATUS)
    (asserts! (get is-active juror-data) ERR-NOT-JUROR)
    
    (map-set case-jurors
      { case-id: case-id, juror: juror }
      {
        assigned-at: block-height,
        has-voted: false
      }
    )
    (ok true)
  )
)

;; Start voting phase
(define-public (start-voting (case-id uint))
  (let
    (
      (case-data (unwrap! (get-case case-id) ERR-CASE-NOT-FOUND))
    )
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (asserts! (is-eq (get status case-data) STATUS-PENDING) ERR-INVALID-STATUS)
    
    (map-set cases
      { case-id: case-id }
      (merge case-data {
        status: STATUS-VOTING,
        voting-ends: (+ block-height (var-get voting-period))
      })
    )
    (ok true)
  )
)

;; Cast vote on a case
(define-public (cast-vote (case-id uint) (vote-for bool) (reasoning (optional (string-utf8 300))))
  (let
    (
      (case-data (unwrap! (get-case case-id) ERR-CASE-NOT-FOUND))
      (case-juror (unwrap! (get-case-juror case-id tx-sender) ERR-NOT-JUROR))
      (juror-data (unwrap! (get-juror tx-sender) ERR-NOT-JUROR))
    )
    (asserts! (is-eq (get status case-data) STATUS-VOTING) ERR-INVALID-STATUS)
    (asserts! (< block-height (get voting-ends case-data)) ERR-VOTING-ENDED)
    (asserts! (not (get has-voted case-juror)) ERR-ALREADY-VOTED)
    
    ;; Record vote
    (map-set votes
      { case-id: case-id, juror: tx-sender }
      {
        vote: vote-for,
        reasoning: reasoning,
        voted-at: block-height
      }
    )
    
    ;; Mark juror as voted
    (map-set case-jurors
      { case-id: case-id, juror: tx-sender }
      (merge case-juror { has-voted: true })
    )
    
    ;; Update vote counts
    (map-set cases
      { case-id: case-id }
      (merge case-data {
        votes-for: (if vote-for (+ (get votes-for case-data) u1) (get votes-for case-data)),
        votes-against: (if vote-for (get votes-against case-data) (+ (get votes-against case-data) u1))
      })
    )
    
    ;; Update juror stats
    (map-set jurors
      { juror: tx-sender }
      (merge juror-data {
        cases-judged: (+ (get cases-judged juror-data) u1)
      })
    )
    
    (ok true)
  )
)

;; Finalize case after voting
(define-public (finalize-case (case-id uint) (resolution (string-utf8 200)))
  (let
    (
      (case-data (unwrap! (get-case case-id) ERR-CASE-NOT-FOUND))
    )
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (asserts! (is-eq (get status case-data) STATUS-VOTING) ERR-INVALID-STATUS)
    (asserts! (>= block-height (get voting-ends case-data)) ERR-VOTING-ENDED)
    
    (map-set cases
      { case-id: case-id }
      (merge case-data {
        status: STATUS-RESOLVED,
        resolution: (some resolution)
      })
    )
    (ok true)
  )
)

;; Update juror stake
(define-public (update-stake (new-stake uint))
  (let
    (
      (juror-data (unwrap! (get-juror tx-sender) ERR-NOT-JUROR))
    )
    (asserts! (>= new-stake (var-get min-juror-stake)) ERR-INSUFFICIENT-STAKE)
    
    (map-set jurors
      { juror: tx-sender }
      (merge juror-data { stake: new-stake })
    )
    (ok true)
  )
)

;; Deactivate juror status
(define-public (deactivate-juror)
  (let
    (
      (juror-data (unwrap! (get-juror tx-sender) ERR-NOT-JUROR))
    )
    (map-set jurors
      { juror: tx-sender }
      (merge juror-data { is-active: false })
    )
    (ok true)
  )
)

;; Admin: Set minimum stake
(define-public (set-min-stake (new-min uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (var-set min-juror-stake new-min)
    (ok true)
  )
)

;; Admin: Set voting period
(define-public (set-voting-period (new-period uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (var-set voting-period new-period)
    (ok true)
  )
)


;; title: arbitration-court
;; version:
;; summary:
;; description:

;; traits
;;

;; token definitions
;;

;; constants
;;

;; data vars
;;

;; data maps
;;

;; public functions
;;

;; read only functions
;;

;; private functions
;;

