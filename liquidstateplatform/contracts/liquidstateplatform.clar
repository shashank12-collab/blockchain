;; ---------- Token ----------
(define-fungible-token staked-stx)

;; ---------- Errors ----------
(define-constant ERR-OWNER-ONLY           (err u100))
(define-constant ERR-INSUFFICIENT-BALANCE (err u101))
(define-constant ERR-INVALID-AMOUNT       (err u102))
(define-constant ERR-NO-STAKED-BALANCE    (err u103))
(define-constant ERR-COOLDOWN-PERIOD      (err u104))
(define-constant ERR-STAKING-DISABLED     (err u105))
(define-constant ERR-BOOTSTRAP-DONE       (err u106))

;; ---------- Metadata (informational only) ----------
(define-data-var token-name     (string-ascii 32) "Liquid Staked STX")
(define-data-var token-symbol   (string-ascii 10) "stSTX")
(define-data-var token-decimals uint u6)

;; ---------- Globals ----------
(define-data-var owner               (optional principal) none)   ;; set once via bootstrap-owner
(define-data-var staking-enabled     bool true)
(define-data-var total-stx-staked    uint u0)
(define-data-var total-ststx-supply  uint u0)
(define-data-var exchange-rate       uint u1000000)  ;; 1.000000 STX / 1 stSTX (fixed-point 1e6)

(define-constant STAKING-COOLDOWN-BLOCKS u144)       ;; ~1 day

;; ---------- Per-user state ----------
(define-map user-stakes principal
  { amount: uint, stake-height: uint, last-claim-height: uint }
)

;; ---------- Internal helpers ----------
(define-private (require-owner)
  (match (var-get owner)
    some-owner (begin
                  (asserts! (is-eq tx-sender some-owner) ERR-OWNER-ONLY)
                  (ok true))        ;; bool ko wrap karke response banaya
    (err u999)                       ;; already response hai
  )
)



;; ---------- Views ----------
(define-read-only (get-owner)           (ok (var-get owner)))
(define-read-only (get-exchange-rate)   (ok (var-get exchange-rate)))
(define-read-only (get-total-staked)    (ok (var-get total-stx-staked)))
(define-read-only (get-ststx-balance (user principal)) (ok (ft-get-balance staked-stx user)))
(define-read-only (get-user-stake (user principal))    (ok (map-get? user-stakes user)))
(define-read-only (get-contract-stats)
  (ok {
    total-stx-staked: (var-get total-stx-staked),
    total-ststx-supply: (var-get total-ststx-supply),
    exchange-rate: (var-get exchange-rate),
    staking-enabled: (var-get staking-enabled),
    owner: (var-get owner)
  })
)

;; Preview helpers (read-only math)
(define-read-only (preview-mint (amount uint))
  (let ((r (var-get exchange-rate))) (ok (/ (* amount u1000000) r)))
)
(define-read-only (preview-redeem (ststx uint))
  (let ((r (var-get exchange-rate))) (ok (/ (* ststx r) u1000000)))
)

;; ---------- One-time owner bootstrap ----------
(define-public (bootstrap-owner (new-owner principal))
  (begin
    (asserts! (is-none (var-get owner)) ERR-BOOTSTRAP-DONE)
    (var-set owner (some new-owner))
    (ok true)
  )
)

(define-public (stake-stx (amount uint))
  (let
    (
      (r (var-get exchange-rate))
      (mint (/ (* amount u1000000) r))
      (prev (default-to { amount: u0, stake-height: u0, last-claim-height: u0 }
                        (map-get? user-stakes tx-sender)))
    )
    (begin
      (asserts! (var-get staking-enabled) ERR-STAKING-DISABLED)
      (asserts! (> amount u0) ERR-INVALID-AMOUNT)
      (asserts! (>= (stx-get-balance tx-sender) amount) ERR-INSUFFICIENT-BALANCE)

      ;; user -> contract
      (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))

      ;; mint stSTX to user
      (try! (ft-mint? staked-stx mint tx-sender))

      ;; update user
      (map-set user-stakes tx-sender
        { amount: (+ (get amount prev) amount),
          stake-height: stacks-block-height,
          last-claim-height: stacks-block-height })

      ;; update globals
      (var-set total-stx-staked (+ (var-get total-stx-staked) amount))
      (var-set total-ststx-supply (+ (var-get total-ststx-supply) mint))

      (ok { staked-amount: amount, ststx-minted: mint, exchange-rate: r })
    )
  )
)

;; ---------- Unstake: burn stSTX, contract -> user (after cooldown) ----------
(define-public (unstake-stx (ststx-amount uint))
  (let
    (
      (r (var-get exchange-rate))
      (stx (/ (* ststx-amount r) u1000000))
      (pos (unwrap! (map-get? user-stakes tx-sender) ERR-NO-STAKED-BALANCE))
      (age (- stacks-block-height (get stake-height pos)))
    )
    (begin
      (asserts! (> ststx-amount u0) ERR-INVALID-AMOUNT)
      (asserts! (>= (ft-get-balance staked-stx tx-sender) ststx-amount) ERR-INSUFFICIENT-BALANCE)
      (asserts! (>= age STAKING-COOLDOWN-BLOCKS) ERR-COOLDOWN-PERIOD)

      ;; burn user's stSTX
      (try! (ft-burn? staked-stx ststx-amount tx-sender))

      ;; contract -> user (need tx-sender == contract; use as-contract)
      (try! (as-contract (stx-transfer? stx tx-sender tx-sender)))

      ;; update user position (full/partial)
      (if (>= stx (get amount pos))
        (map-delete user-stakes tx-sender)
        (map-set user-stakes tx-sender
          { amount: (- (get amount pos) stx),
            stake-height: (get stake-height pos),
            last-claim-height: stacks-block-height })
      )

      ;; update globals
      (var-set total-stx-staked (- (var-get total-stx-staked) stx))
      (var-set total-ststx-supply (- (var-get total-ststx-supply) ststx-amount))

      (ok { ststx-burned: ststx-amount, stx-returned: stx, exchange-rate: r })
    )
  )
)

;; ---------- Admin ----------
(define-public (update-exchange-rate (new-rate uint))
  (begin
    (try! (require-owner))  
    (asserts! (> new-rate u0) ERR-INVALID-AMOUNT)
    (var-set exchange-rate new-rate)
    (ok true)
  )
)

(define-public (toggle-staking (enabled bool))
  (begin
    (try! (require-owner)) 
    (var-set staking-enabled enabled)
    (ok true)
  )
)
