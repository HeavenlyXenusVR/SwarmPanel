/// The Apple TV app's telemetry is now the shared ClientTelemetry (see
/// ios/Shared/ClientTelemetry.swift), which the iPhone app uses too -- the
/// iOS target previously had no telemetry at all, so "ios" never appeared in
/// the server-side client telemetry. The name is kept as an alias so the
/// existing TV call sites (TVSession, TVDashboardModel, TVAccount, the views)
/// read unchanged.
typealias TVTelemetry = ClientTelemetry
