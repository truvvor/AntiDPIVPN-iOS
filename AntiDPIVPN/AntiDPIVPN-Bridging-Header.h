//
//  AntiDPIVPN-Bridging-Header.h
//  AntiDPIVPN
//
//  Main app does NOT import LibXray.
//  LibXray (Go-based xray-core) contains a FIPS-140-3 integrity check
//  that aborts at runtime when iOS re-signs the host binary. Importing
//  <LibXray/LibXray.h> here triggered Swift clang-module auto-link,
//  which statically linked Go runtime + x/crypto into AntiDPIVPN.app
//  and caused SIGABRT at launch (builds 81-85).
//
//  LibXray now lives ONLY in PacketTunnelExtension. The main app reads
//  the xray version from App Group UserDefaults (key "xray_version"),
//  populated by the extension on first start, and via live IPC
//  ("getXrayVersion") when the tunnel is active.
//

#ifndef AntiDPIVPN_Bridging_Header_h
#define AntiDPIVPN_Bridging_Header_h

#endif /* AntiDPIVPN_Bridging_Header_h */
