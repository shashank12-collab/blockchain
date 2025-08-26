import { describe, expect, it } from "vitest";

const accounts = simnet.getAccounts();
const address1 = accounts.get("wallet_1")!;

describe("example tests", () => {
  it("ensures simnet is well initialised", () => {
    expect(simnet.blockHeight).toBeDefined();
  });

  it("stakes stx and mints stSTX", () => {
    const callResponse = simnet.callPublicFn(
      "liquidstateplatform",
      "stake-stx",
      [uintCV(1000000)],
      address1
    );
    expect(callResponse.result).toBeDefined();
    // Agar aapko exact success check karna hai to clarity 'ok' type ka check karein
    expect(callResponse.result.type).toBe("ok");
  });
});
