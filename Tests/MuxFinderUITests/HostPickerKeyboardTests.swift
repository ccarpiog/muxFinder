import AppKit
import MuxFinderCore
import SwiftUI
import Testing

@testable import MuxFinderUI

/// The panels' key routing (PLAN.md Phase I-8, D30, D31, D32): `PanelKeyRoute.decide`, the pure
/// decision the popover's and the switcher's key monitor make for each key press. With a
/// pop-up button focused (New session's Host picker), ↑, ↓ and ⌥↓ go on to it while Return and
/// Esc keep their meaning, the directory list's included; with any other focus nothing changes;
/// while a menu tracks or an input method composes, every key goes on untouched. No event is
/// made: the decision takes the key as a `PopoverKey` value.
@Suite("Panel key routing")
@MainActor
struct PanelKeyRouteTests {
  /// Every panel key, then no key (Space, Tab, a letter: `PopoverKey` is `nil` for them).
  static let keys: [PopoverKey?] = PopoverKey.allCases.map { $0 } + [nil]

  /// The decision for `key` with nothing tracking or composing.
  static func route(
    _ key: PopoverKey?, _ responder: PanelFirstResponder, listOpen: Bool
  ) -> PanelKeyRoute {
    PanelKeyRoute.decide(
      key, firstResponder: responder, menuTracking: false, hasMarkedText: false,
      directoryListOpen: listOpen)
  }

  /// Space is no panel key, so it always reaches the focused view (a pop-up button's menu
  /// opens on it, as AppKit gives it).
  @Test("Space is no panel key")
  func spaceIsNoPanelKey() {
    #expect(PopoverKey(keyCode: 49, modifierFlags: [], charactersIgnoringModifiers: " ") == nil)
    for responder in [PanelFirstResponder.popUpButton, .other] {
      for listOpen in [false, true] {
        #expect(Self.route(nil, responder, listOpen: listOpen) == .focusedView)
      }
    }
  }

  /// With the pop-up button focused and the directory list closed: ↑, ↓ and ⌥↓ go on to it;
  /// Return still creates and Esc still closes the panel (the handler's `open` and `close`);
  /// ⌘F, ⌘R, ⌘N and ⌘, are the handler's as before.
  @Test("A focused pop-up button keeps the arrows")
  func aPopUpButtonKeepsTheArrows() {
    for key in [PopoverKey.up, .down, .openList] {
      #expect(Self.route(key, .popUpButton, listOpen: false) == .focusedView)
      #expect(Self.route(key, .popUpButton, listOpen: false).handlerKey == nil)
    }
    #expect(Self.route(.open, .popUpButton, listOpen: false) == .model(.open))
    #expect(Self.route(.close, .popUpButton, listOpen: false) == .model(.close))
    for key in [PopoverKey.find, .refresh, .newSession, .settings] {
      #expect(Self.route(key, .popUpButton, listOpen: false) == .model(key))
    }
  } // End of func aPopUpButtonKeepsTheArrows()

  /// With the directory list open and the pop-up button focused: ↑, ↓ and ⌥↓ go on to the
  /// picker (the list never sees them, so its highlight stays), Return and Esc keep their
  /// list meaning (the list's `open` picks the highlighted row or creates, its `close` closes
  /// the list first), and ⌘F, ⌘R, ⌘N and ⌘, are the panel's.
  @Test("With the list open a focused pop-up button still keeps the arrows")
  func theListOpenAndThePopUpButtonFocused() {
    for key in [PopoverKey.up, .down, .openList] {
      #expect(Self.route(key, .popUpButton, listOpen: true) == .focusedView)
    }
    #expect(Self.route(.open, .popUpButton, listOpen: true) == .directoryList(.open))
    #expect(Self.route(.close, .popUpButton, listOpen: true) == .directoryList(.close))
    for key in [PopoverKey.find, .refresh, .newSession, .settings] {
      #expect(Self.route(key, .popUpButton, listOpen: true) == .model(key))
    }
  }

  /// Name, Directory (their field editor), the list's button, nothing focused or the window:
  /// exactly the mapping before Phase I-8. Every panel key goes to the handler (the list's keys
  /// as the list's while it is open), no key goes on.
  @Test("Any other focus keeps the old mapping")
  func otherFocusKeepsTheOldMapping() {
    let editor = NSTextView()
    editor.isFieldEditor = true
    let responders: [NSResponder?] = [
      NSTextField(string: "work"), editor, NSButton(title: "", target: nil, action: nil), NSView(),
      NSResponder(), nil,
    ]
    for responder in responders {
      #expect(PanelFirstResponder(responder) == .other)
    }
    for key in PopoverKey.allCases {
      #expect(Self.route(key, .other, listOpen: false) == .model(key))
      #expect(Self.route(key, .other, listOpen: true).handlerKey == key)
    }
    for key in [PopoverKey.up, .down, .openList, .open, .close] {
      #expect(Self.route(key, .other, listOpen: true) == .directoryList(key))
    }
    for key in [PopoverKey.find, .refresh, .newSession, .settings] {
      #expect(Self.route(key, .other, listOpen: true) == .model(key))
    }
    #expect(Self.route(nil, .other, listOpen: false) == .focusedView)
  } // End of func otherFocusKeepsTheOldMapping()

  /// Only an `NSPopUpButton` (a pop-up or a pull-down, a subclass such as SwiftUI's picker
  /// included) is a pop-up button.
  @Test("Which responders are pop-up buttons")
  func firstResponderKinds() {
    /// A subclass, as SwiftUI's `Picker` is.
    final class Subclass: NSPopUpButton {}
    #expect(PanelFirstResponder(NSPopUpButton(frame: .zero, pullsDown: false)) == .popUpButton)
    #expect(PanelFirstResponder(NSPopUpButton(frame: .zero, pullsDown: true)) == .popUpButton)
    #expect(PanelFirstResponder(Subclass(frame: .zero, pullsDown: false)) == .popUpButton)
    #expect(PanelFirstResponder(NSButton(frame: .zero)) == .other)
  }

  /// While a menu tracks, every key goes on untouched, whatever has the focus, the list's
  /// state and marked text.
  @Test("A tracking menu gets every key")
  func aTrackingMenuGetsEveryKey() {
    for key in Self.keys {
      for responder in [PanelFirstResponder.popUpButton, .other] {
        for listOpen in [false, true] {
          for marked in [false, true] {
            let route = PanelKeyRoute.decide(
              key, firstResponder: responder, menuTracking: true, hasMarkedText: marked,
              directoryListOpen: listOpen)
            #expect(route == .menu)
            #expect(route.handlerKey == nil)
          }
        }
      } // End of loop over the focus kinds
    } // End of loop over the keys
  } // End of func aTrackingMenuGetsEveryKey()

  /// While an input method composes text, every key goes to it, as before Phase I-8.
  @Test("Marked text gets every key")
  func markedTextGetsEveryKey() {
    for key in Self.keys {
      for responder in [PanelFirstResponder.popUpButton, .other] {
        for listOpen in [false, true] {
          let route = PanelKeyRoute.decide(
            key, firstResponder: responder, menuTracking: false, hasMarkedText: true,
            directoryListOpen: listOpen)
          #expect(route == .inputMethod)
        }
      }
    } // End of loop over the keys
  } // End of func markedTextGetsEveryKey()

  /// The keys the routing calls the directory list's are exactly those the model's open list
  /// answers (`handleDirectoryListKey(_:)`), each tried on a fresh model with the list open.
  @Test("The directory list's keys are the model's")
  func theDirectoryListKeysAreTheModels() {
    for key in PopoverKey.allCases {
      let model = DirectoryPickerModelTests.fixtureModel()
      model.openDirectoryList(highlightingFirst: true)
      #expect(model.directoryPicker.isOpen)
      let answered = model.handleDirectoryListKey(key) != nil
      #expect(answered == PanelKeyRoute.directoryListKeys.contains(key), "\(key)")
    }
  }

  /// The diagnostic's keys (`KeyViewLoopReport.routedKeys`) are the panel keys a real press
  /// carries: ↑, ↓, ⌥↓, Space (none), Return and Esc.
  @Test("The diagnostic's keys")
  func theDiagnosticsKeys() {
    let keys = KeyViewLoopReport.routedKeys.map {
      PopoverKey(
        keyCode: $0.keyCode, modifierFlags: $0.flags, charactersIgnoringModifiers: $0.characters)
    }
    #expect(keys == [.up, .down, .openList, nil, .open, .close])
    #expect(KeyViewLoopReport.describe(.model(.open)) == "the panel's open")
    #expect(KeyViewLoopReport.describe(.focusedView) == "the focused view")
  }
}

/// `MenuTrackingObserver` (PLAN.md Phase I-8) over a private notification center: a menu
/// tracks from its begin notification to its end; nested menus count apart; an end whose
/// begin was never seen forgets every menu, so the panels' keys are never left passing through.
@Suite("Menu tracking observer")
@MainActor
struct MenuTrackingObserverTests {
  /// Posts `name` for `menu` on `center`.
  static func post(_ name: Notification.Name, _ menu: NSMenu?, on center: NotificationCenter) {
    center.post(name: name, object: menu)
  }

  /// A begin, then its end.
  @Test("A menu tracks between its begin and end")
  func beginAndEnd() {
    let center = NotificationCenter()
    let observer = MenuTrackingObserver(center: center)
    let menu = NSMenu()
    #expect(!observer.isTracking)
    Self.post(NSMenu.didBeginTrackingNotification, menu, on: center)
    #expect(observer.isTracking)
    Self.post(NSMenu.didEndTrackingNotification, menu, on: center)
    #expect(!observer.isTracking)
  }

  /// Two menus tracking: the first end leaves the other tracking.
  @Test("Nested menus")
  func nestedMenus() {
    let center = NotificationCenter()
    let observer = MenuTrackingObserver(center: center)
    let (outer, inner) = (NSMenu(), NSMenu())
    Self.post(NSMenu.didBeginTrackingNotification, outer, on: center)
    Self.post(NSMenu.didBeginTrackingNotification, inner, on: center)
    Self.post(NSMenu.didEndTrackingNotification, inner, on: center)
    #expect(observer.isTracking)
    Self.post(NSMenu.didEndTrackingNotification, outer, on: center)
    #expect(!observer.isTracking)
  } // End of func nestedMenus()

  /// An end for a menu whose begin was never seen forgets every menu; a notification without
  /// a menu counts as one menu.
  @Test("An unbalanced end forgets every menu")
  func unbalancedEnd() {
    let center = NotificationCenter()
    let observer = MenuTrackingObserver(center: center)
    let (tracked, other) = (NSMenu(), NSMenu())
    Self.post(NSMenu.didBeginTrackingNotification, tracked, on: center)
    Self.post(NSMenu.didEndTrackingNotification, other, on: center)
    #expect(!observer.isTracking)
    Self.post(NSMenu.didBeginTrackingNotification, nil, on: center)
    #expect(observer.isTracking)
    Self.post(NSMenu.didEndTrackingNotification, nil, on: center)
    #expect(!observer.isTracking)
  } // End of func unbalancedEnd()

  /// Another center's notifications, and other menu notifications, change nothing.
  @Test("Only its center's tracking notifications count")
  func onlyItsCenter() {
    let center = NotificationCenter()
    let observer = MenuTrackingObserver(center: center)
    let menu = NSMenu()
    Self.post(NSMenu.didBeginTrackingNotification, menu, on: NotificationCenter())
    Self.post(NSMenu.didSendActionNotification, menu, on: center)
    #expect(!observer.isTracking)
  }
}

/// New session's Host picker writes the host through its binding (PLAN.md Phase I-8, D31). A
/// click, the keyboard (Space or an arrow, then Return in the open menu) and VoiceOver all pick
/// through AppKit's own pop-up menu, which sets the pop-up button's selection; SwiftUI then
/// writes it through the picker's binding, `$model.newSessionDraft.hostID`, so a pick acts the
/// same whatever made it. (A window that is never shown gets no AppKit pop-up button from
/// SwiftUI, so the binding is driven here as the picker drives it; the real picker's class is
/// read by `--preview-key-view-loop`.)
@Suite("New session: the Host picker's binding")
@MainActor
struct HostPickerBindingTests {
  /// The preview fixtures, as the other model tests name them.
  typealias Fixtures = PreviewFixtures

  /// A host written through the picker's binding changes the draft's host, re-filters the
  /// directory list for it (its title names the host), keeps Name and Directory, and neither
  /// closes an open list nor opens a closed one.
  @Test("A host picked through the picker's binding")
  func aHostPickedThroughThePickersBinding() {
    let model = DirectoryFilterModelTests.model()
    model.newSessionDraft.name = "muxfinder-test-host"
    model.newSessionDraft.directory = "proj"
    #expect(model.directoryPicker.isOpen, "typing that matches opened the list")
    #expect(model.directoryPickerContent?.hostName == "Saturno")
    let selection = Bindable(model).newSessionDraft.hostID
    selection.wrappedValue = Fixtures.neptuno.id
    #expect(model.newSessionDraft.hostID == Fixtures.neptuno.id)
    #expect(model.newSessionDraft.name == "muxfinder-test-host")
    #expect(model.newSessionDraft.directory == "proj")
    #expect(model.directoryPickerContent?.hostName == "Neptuno")
    #expect(model.directoryPicker.isOpen, "a host change closes nothing")

    _ = model.handleNewSessionKey(.close)
    #expect(!model.directoryPicker.isOpen)
    selection.wrappedValue = Fixtures.saturno.id
    #expect(model.newSessionDraft.hostID == Fixtures.saturno.id)
    #expect(model.directoryPickerContent?.hostName == "Saturno")
    #expect(!model.directoryPicker.isOpen, "a host change opens nothing")
    #expect(model.newSessionDraft.directory == "proj")
  } // End of func aHostPickedThroughThePickersBinding()
}
