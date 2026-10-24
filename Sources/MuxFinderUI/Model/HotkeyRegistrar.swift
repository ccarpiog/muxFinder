import Carbon.HIToolbox
import Foundation
import MuxFinderCore

/// One registered hotkey, as `HotkeyRegistering` hands it out.
public struct HotkeyToken: Sendable, Hashable {
  /// The registration's number (Carbon's `EventHotKeyID.id`).
  public var id: UInt32

  /// A token with `id`.
  public init(id: UInt32) {
    self.id = id
  }
}

/// Why a hotkey could not be registered or unregistered (PLAN.md D32): Carbon's `OSStatus`
/// mapped to kinds.
public enum HotkeyRegistrationError: Error, Sendable, Hashable {
  /// The combination is registered already: by this process, or exclusively by another app
  /// (`eventHotKeyExistsErr`).
  case taken
  /// macOS refused the combination (`eventHotKeyInvalidErr` or `paramErr`).
  case invalid(OSStatus)
  /// Any other failure, with Carbon's status.
  case failed(OSStatus)
  /// The token names no registration of this registrar.
  case unknownToken

  /// The error for a Carbon status that is not `noErr`.
  public init(status: OSStatus) {
    switch Int(status) {
    case eventHotKeyExistsErr: self = .taken
    case eventHotKeyInvalidErr, paramErr: self = .invalid(status)
    default: self = .failed(status)
    }
  }

  /// A stable, machine-readable name (diagnostics and logs record it, never the shortcut).
  public var code: String {
    switch self {
    case .taken: return "taken"
    case .invalid(let status): return "invalid(\(status))"
    case .failed(let status): return "failed(\(status))"
    case .unknownToken: return "unknownToken"
    }
  }

  /// The user-facing explanation, shown beside the recorder (never an alert).
  public var message: String {
    switch self {
    case .taken:
      return "Another app uses this shortcut. Choose another."
    case .invalid:
      return "macOS doesn't accept this shortcut. Choose another."
    case .failed(let status):
      return "macOS couldn't turn on this shortcut (error \(status)). Choose another."
    case .unknownToken:
      return "muxFinder lost track of this shortcut. Record it again."
    }
  } // End of var message

  /// The user-facing explanation of a failed unregistration, shown beside the recorder (never
  /// an alert): the hotkey is still registered, so it still works.
  public var unregistrationMessage: String {
    switch self {
    case .taken:
      return "macOS couldn't turn off the shortcut (error \(eventHotKeyExistsErr)), so it still "
        + "works."
    case .invalid(let status), .failed(let status):
      return "macOS couldn't turn off the shortcut (error \(status)), so it still works."
    case .unknownToken:
      return "muxFinder lost track of the shortcut."
    }
  } // End of var unregistrationMessage
}

/// Registers system-wide hotkeys (PLAN.md D32): `CarbonHotkeyRegistrar` in the app and the
/// registration diagnostic, a fake that can fire its callback in tests.
@MainActor
public protocol HotkeyRegistering: AnyObject, Sendable {
  /// Called on the main actor with the token of a hotkey when it is pressed.
  var onPress: (@MainActor (HotkeyToken) -> Void)? { get set }
  /// Registers `shortcut` system-wide and returns its token.
  func register(_ shortcut: GlobalShortcut) throws(HotkeyRegistrationError) -> HotkeyToken
  /// Unregisters the hotkey `token` names. When that fails the registration is kept, and the
  /// token still names it, so a later call can try again.
  func unregister(_ token: HotkeyToken) throws(HotkeyRegistrationError)
}

/// The Carbon calls `CarbonHotkeyRegistrar` makes (PLAN.md D32): Carbon's own (`carbon`) in the
/// app and the diagnostic; tests pass fakes, so no real hotkey or handler is ever installed.
struct CarbonHotkeyCalls {
  /// `RegisterEventHotKey` of a key code and Carbon modifier mask with this id, exclusively, for
  /// the application event target: Carbon's status and the registration.
  var register: @MainActor (UInt32, UInt32, EventHotKeyID) -> (OSStatus, EventHotKeyRef?)
  /// `UnregisterEventHotKey`.
  var unregister: @MainActor (EventHotKeyRef) -> OSStatus
  /// `InstallEventHandler` of the `kEventHotKeyPressed` handler for this registrar on the event
  /// dispatcher target: Carbon's status and the handler.
  var installHandler: @MainActor (CarbonHotkeyRegistrar) -> (OSStatus, EventHandlerRef?)
  /// `RemoveEventHandler`.
  var removeHandler: @MainActor (EventHandlerRef) -> Void

  /// Carbon's own calls. The handler hands muxFinder's presses (its signature) to the
  /// registrar, unretained; any other event goes on as not handled.
  static var carbon: CarbonHotkeyCalls {
    CarbonHotkeyCalls(
      register: { keyCode, modifiers, identifier in
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
          keyCode, modifiers, identifier, GetApplicationEventTarget(),
          OptionBits(kEventHotKeyExclusive), &reference)
        return (status, reference)
      },
      unregister: { UnregisterEventHotKey($0) },
      installHandler: { registrar in
        var type = EventTypeSpec(
          eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        var installed: EventHandlerRef?
        let status = InstallEventHandler(
          GetEventDispatcherTarget(),
          { _, event, userData -> OSStatus in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let status = GetEventParameter(
              event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
              nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard status == noErr, identifier.signature == CarbonHotkeyRegistrar.signature else {
              return OSStatus(eventNotHandledErr)
            }
            let token = HotkeyToken(id: identifier.id)
            let pointer = UInt(bitPattern: userData)
            // Carbon calls the handler on the main thread, from the app's event loop.
            MainActor.assumeIsolated {
              guard let raw = UnsafeRawPointer(bitPattern: pointer) else { return }
              let registrar = Unmanaged<CarbonHotkeyRegistrar>.fromOpaque(raw)
                .takeUnretainedValue()
              registrar.pressed(token)
            }
            return noErr
          },
          1, &type, Unmanaged.passUnretained(registrar).toOpaque(), &installed)
        return (status, installed)
      },
      removeHandler: { RemoveEventHandler($0) })
  } // End of static var carbon
}

/// Carbon's hotkeys (`RegisterEventHotKey`, PLAN.md D32): system-wide, with no Accessibility
/// or Input Monitoring permission. A combination is registered for the application event
/// target, and its `kEventHotKeyPressed` events are caught by a handler on the event
/// dispatcher target, which every event the app's main run loop dispatches passes through
/// (MASShortcut's arrangement), whatever AppKit does with the application target.
///
/// - Every combination is registered with `kEventHotKeyExclusive`: an app that registered the
///   same combination exclusively makes the registration fail with `eventHotKeyExistsErr`
///   (`taken`), and while muxFinder holds it, non-exclusive registrants of other apps do not
///   get it. A second registration of a combination this process holds fails the same way.
/// - A registration is forgotten only once `UnregisterEventHotKey` succeeded: one that failed
///   keeps its reference and its token (its presses still arrive), so `unregister(_:)` or
///   `unregisterAll()` can try again; nothing is ever left registered without a handle.
/// - The handler is installed at the first registration and removed by `unregisterAll()`
///   once nothing is registered. Unregistering everything is also what the system does when
///   the process exits.
/// - Not thread safe (Carbon's own rule): main actor only. The handler refers to the registrar
///   without retaining it, so the registrar must outlive its registrations (the app's lives as
///   long as the process; the diagnostic calls `unregisterAll()` before it exits).
@MainActor
public final class CarbonHotkeyRegistrar: HotkeyRegistering {
  /// The signature in every `EventHotKeyID` muxFinder registers ("mxfd").
  public static let signature: OSType = 0x6D78_6664

  /// Called with the token of a pressed hotkey.
  public var onPress: (@MainActor (HotkeyToken) -> Void)?
  /// The Carbon calls (Carbon's own outside tests).
  private let calls: CarbonHotkeyCalls
  /// The registrations, by token.
  private var registrations: [HotkeyToken: EventHotKeyRef] = [:]
  /// The last token number handed out.
  private var lastID: UInt32 = 0
  /// The installed `kEventHotKeyPressed` handler, if any.
  private var handler: EventHandlerRef?

  /// A registrar on Carbon's own calls, with nothing registered and no handler installed.
  public convenience init() {
    self.init(calls: .carbon)
  }

  /// A registrar on `calls` (tests pass fakes), with nothing registered and no handler.
  init(calls: CarbonHotkeyCalls) {
    self.calls = calls
  }

  /// How many hotkeys are registered now (one whose unregistration failed included).
  public var registeredCount: Int { registrations.count }

  /// Whether the `kEventHotKeyPressed` handler is installed (tests).
  var isHandlerInstalled: Bool { handler != nil }

  /// Registers `shortcut` exclusively on the application event target.
  public func register(_ shortcut: GlobalShortcut) throws(HotkeyRegistrationError) -> HotkeyToken {
    try installHandlerIfNeeded()
    lastID &+= 1
    let token = HotkeyToken(id: lastID)
    let (status, reference) = calls.register(
      UInt32(shortcut.keyCode), Self.carbonModifiers(shortcut.modifiers),
      EventHotKeyID(signature: Self.signature, id: token.id))
    guard status == noErr, let reference else {
      throw HotkeyRegistrationError(status: status == noErr ? OSStatus(paramErr) : status)
    }
    registrations[token] = reference
    return token
  } // End of func register(_:)

  /// Unregisters the hotkey `token` names. The registration is forgotten only when Carbon
  /// unregistered it; otherwise it is kept (with the token) and the failure thrown.
  public func unregister(_ token: HotkeyToken) throws(HotkeyRegistrationError) {
    guard let reference = registrations[token] else { throw .unknownToken }
    let status = calls.unregister(reference)
    guard status == noErr else { throw HotkeyRegistrationError(status: status) }
    registrations[token] = nil
  }

  /// Unregisters every hotkey and returns how many are still registered: those whose
  /// unregistration failed, kept so a later call can try again. Removes the handler once
  /// nothing is registered.
  @discardableResult
  public func unregisterAll() -> Int {
    for (token, reference) in registrations where calls.unregister(reference) == noErr {
      registrations[token] = nil
    }
    if registrations.isEmpty, let handler {
      calls.removeHandler(handler)
      self.handler = nil
    }
    return registrations.count
  } // End of func unregisterAll()

  /// Carbon's modifier mask for `modifiers`.
  static func carbonModifiers(_ modifiers: GlobalShortcut.Modifiers) -> UInt32 {
    var mask = 0
    if modifiers.contains(.control) { mask |= controlKey }
    if modifiers.contains(.option) { mask |= optionKey }
    if modifiers.contains(.shift) { mask |= shiftKey }
    if modifiers.contains(.command) { mask |= cmdKey }
    return UInt32(mask)
  }

  /// Installs the `kEventHotKeyPressed` handler, once.
  private func installHandlerIfNeeded() throws(HotkeyRegistrationError) {
    guard handler == nil else { return }
    let (status, installed) = calls.installHandler(self)
    guard status == noErr else { throw HotkeyRegistrationError(status: status) }
    handler = installed
  }

  /// A hotkey of this registrar was pressed: only a registration it still holds reaches
  /// `onPress`.
  func pressed(_ token: HotkeyToken) {
    guard registrations[token] != nil else { return }
    onPress?(token)
  }
}
