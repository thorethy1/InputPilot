#include <cassert>
#include <sys/socket.h>

#include "CaptivePortalPolicy.h"

using CaptivePortalPolicy::AddressFamily;
using CaptivePortalPolicy::Gate;
using CaptivePortalPolicy::GateState;

static void testParseAddressFamily() {
  AddressFamily family = AddressFamily::Auto;
  assert(CaptivePortalPolicy::parseAddressFamily("AUTO", family));
  assert(family == AddressFamily::Auto);
  assert(CaptivePortalPolicy::parseAddressFamily("IPV4", family));
  assert(family == AddressFamily::IPv4);
  assert(!CaptivePortalPolicy::parseAddressFamily("IPV6", family));
  assert(!CaptivePortalPolicy::parseAddressFamily("foo", family));
  assert(CaptivePortalPolicy::resolverFamily(AddressFamily::IPv4) == AF_INET);
  assert(CaptivePortalPolicy::resolverFamily(AddressFamily::Auto) == AF_UNSPEC);
}

static void testGateBlocksWireGuard() {
  // Waiting and running states block.
  Gate gate;
  gate.associate("home", true);
  assert(gate.state() == GateState::Waiting);
  assert(gate.blocksWireGuard());

  gate.start("home");
  assert(gate.state() == GateState::Running);
  assert(gate.blocksWireGuard());

  // Success and ALREADY_CONNECTED release.
  gate.finish("home", GateState::Success);
  assert(gate.state() == GateState::Success);
  assert(!gate.blocksWireGuard());

  Gate again;
  again.associate("home", true);
  again.start("home");
  again.finish("home", GateState::AlreadyConnected);
  assert(again.state() == GateState::AlreadyConnected);
  assert(!again.blocksWireGuard());

  // Failure keeps blocking.
  Gate failed;
  failed.associate("home", true);
  failed.start("home");
  failed.finish("home", GateState::Failed);
  assert(failed.state() == GateState::Failed);
  assert(failed.blocksWireGuard());

  // Result from another SSID is ignored.
  Gate other;
  other.associate("A", true);
  other.finish("B", GateState::Success);
  assert(other.state() == GateState::Waiting);
  assert(other.blocksWireGuard());

  // New association discards the old SSID's result.
  other.start("A");
  other.finish("A", GateState::Success);
  other.associate("B", true);
  assert(other.state() == GateState::Waiting);
  assert(other.blocksWireGuard());

  // Reconnect of the same SSID re-evaluates: disconnect resets the gate.
  other.finish("B", GateState::Success);
  other.disconnect();
  assert(other.state() == GateState::NotRequired);
  assert(!other.blocksWireGuard());
  other.associate("B", true);
  assert(other.state() == GateState::Waiting);

  // No script / disabled script never blocks.
  Gate none;
  none.associate("C", false);
  assert(none.state() == GateState::NotRequired);
  assert(!none.blocksWireGuard());

  // finish() rejects invalid result values.
  Gate reject;
  reject.associate("C", true);
  reject.finish("C", GateState::Waiting);
  assert(reject.state() == GateState::Waiting);
}

static void testBlocksWireGuardStates() {
  assert(CaptivePortalPolicy::blocksWireGuard(GateState::NotRequired) == false);
  assert(CaptivePortalPolicy::blocksWireGuard(GateState::Waiting) == true);
  assert(CaptivePortalPolicy::blocksWireGuard(GateState::Running) == true);
  assert(CaptivePortalPolicy::blocksWireGuard(GateState::Success) == false);
  assert(CaptivePortalPolicy::blocksWireGuard(GateState::AlreadyConnected) == false);
  assert(CaptivePortalPolicy::blocksWireGuard(GateState::Failed) == true);
}

int main() {
  testParseAddressFamily();
  testGateBlocksWireGuard();
  testBlocksWireGuardStates();
  return 0;
}