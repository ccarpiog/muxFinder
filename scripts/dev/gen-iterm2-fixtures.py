"""Generates the iTerm2 protobuf golden fixtures used by muxFinder's tests.

Dev-time only. Run it with iTerm2's bundled interpreter and -I (isolated mode), from any
directory:

    "$HOME/Library/Application Support/iTerm2/iterm2env-3.14/versions/3.14.0/bin/python3" -I \
        scripts/dev/gen-iterm2-fixtures.py

It writes binary .bin files to Tests/MuxFinderCoreTests/Fixtures/iterm2/ and prints their names.
The generated files are committed; `swift test` never needs Python. Re-running it must reproduce
them byte for byte.

How the fixtures are made:

- Requests (*-request*.bin) are built by iTerm2's own Python module: its `iterm2.rpc` functions
  run against a stand-in connection that keeps the request instead of sending it. Only the
  request id is then replaced with a fixed value. The bytes are the module's `SerializeToString`
  output, exactly what it would send over the socket.
- Responses (*-response*.bin and the others) are built with `api_pb2` directly. Some carry fields
  muxFinder's decoder does not model, plus unknown field numbers of every wire type, to prove
  they are skipped.
- Merge fixtures (*-split.bin, *-reserialized.bin, *-unknown-fields.bin, *-then-unmodeled.bin,
  *-after-unmodeled.bin) concatenate serialized pieces, which protobuf parses as a merge: a
  response split across several occurrences, oneof members replacing each other, unknown fields
  after a response. The script checks that `api_pb2` parses each one to the value the Swift
  tests expect, so those expectations are backed by the reference implementation.
- `close-response-packed.bin` is written by hand as a packed run of the repeated enum (iTerm2
  writes it unpacked); the script checks that `api_pb2` reads the same statuses from it.

Every value is synthetic: made-up ids, titles such as "fixture-title-1", and commands such as
/usr/bin/true. Nothing comes from this machine's windows, sessions, hosts or users.

iTerm2's module is GPLv2 and muxFinder is MIT: this script only calls the module at dev time; no
code is copied from it (PLAN.md D1).
"""

import asyncio
import json
import os
import sys

# Never write bytecode caches into iTerm2's runtime directory.
sys.dont_write_bytecode = True

# The site-packages directory of iTerm2's bundled Python runtime (iterm2 module 2.11).
DEFAULT_SITE_PACKAGES = os.path.expanduser(
    "~/Library/Application Support/iTerm2/iterm2env-3.14/versions/3.14.0/lib/python3.14/"
    "site-packages")

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUTPUT_DIRECTORY = os.path.join(REPO_ROOT, "Tests", "MuxFinderCoreTests", "Fixtures", "iterm2")


def add_site_packages():
    """Puts iTerm2's site-packages (or the running interpreter's) first on sys.path."""
    version = f"python{sys.version_info.major}.{sys.version_info.minor}"
    candidates = [
        DEFAULT_SITE_PACKAGES,
        os.path.join(sys.prefix, "lib", version, "site-packages"),
    ]
    for path in reversed(candidates):
        if os.path.isdir(os.path.join(path, "iterm2")) and path not in sys.path:
            sys.path.insert(0, path)


add_site_packages()
try:
    import iterm2
    import iterm2.profile
    import iterm2.rpc
    from iterm2 import api_pb2
except ImportError as error:
    sys.exit(f"Cannot import iTerm2's Python module ({error}). Run this script with iTerm2's "
             "bundled interpreter (see the top of this file).")

# Synthetic identifiers. None of them exists anywhere.
SESSION_1 = "00000000-0000-4000-8000-000000000001"
SESSION_2 = "00000000-0000-4000-8000-000000000002"
SESSION_3 = "00000000-0000-4000-8000-000000000003"
SESSION_4 = "00000000-0000-4000-8000-000000000004"
SESSION_5 = "00000000-0000-4000-8000-000000000005"
SESSION_6 = "00000000-0000-4000-8000-000000000006"
SESSION_7 = "00000000-0000-4000-8000-000000000007"
GUID_1 = "00000000-0000-4000-8000-0000000000a1"
GUID_2 = "00000000-0000-4000-8000-0000000000a2"
WINDOW_1 = "fixture-window-1"
WINDOW_2 = "fixture-window-2"
CONNECTION_1 = "fixture-connection-1"
CONNECTION_2 = "fixture-connection-2"
PROFILE_1 = "fixture-profile-1"
LAUNCH_COMMAND = ("/Applications/muxFinder.app/Contents/MacOS/muxfinder-launch attach "
                  "00000000-0000-0000-0000-000000000000")
# Exercises every JSON escape the module's json.dumps produces: quotes, backslash, the short
# control escapes, other control characters, DEL, Latin-1, CJK and a character above U+FFFF.
ESCAPING_COMMAND = ("/tmp/fixture dir/run \"quoted\" 'single' back\\slash \b\f\n\r\t "
                    "\x01\x1f\x7f \u00fc \u65e5\u672c \U0001F9EA end")


class CapturingConnection:
    """Stands in for iterm2.Connection: keeps the first request instead of sending it."""

    def __init__(self):
        self.request = None

    async def async_send_message(self, message):
        """Keeps the first message the module built (later ones are follow-up calls, such as the
        list_sessions that Window.async_create makes after its create_tab)."""
        if self.request is None:
            self.request = message

    async def async_dispatch_until_id(self, request_id):
        """Answers with an empty response (status OK, nothing listed) so the call returns."""
        return api_pb2.ServerOriginatedMessage()


def module_request(request_id, call):
    """Runs `call(connection)` (a call into iTerm2's module) and returns the first request it
    built, as bytes.

    The module numbers requests from 0 in call order; the id is replaced with `request_id` so
    each fixture is stable on its own.
    """
    connection = CapturingConnection()
    asyncio.run(call(connection))
    request = connection.request
    request.id = request_id
    return request.SerializeToString()
    # End of def module_request()


def varint(value):
    """Encodes a non-negative integer as a protobuf varint."""
    out = bytearray()
    while value >= 0x80:
        out.append((value & 0x7F) | 0x80)
        value >>= 7
    out.append(value)
    return bytes(out)


def unknown_fields(first_number):
    """Fields numbered from `first_number` that no muxFinder message models, one per wire type:
    varint, fixed64, length-delimited and fixed32."""
    n = first_number
    return (varint(n << 3 | 0) + varint(300)
            + varint((n + 1) << 3 | 1) + bytes(range(1, 9))
            + varint((n + 2) << 3 | 2) + varint(len(b"fixture-unknown")) + b"fixture-unknown"
            + varint((n + 3) << 3 | 5) + bytes([0xAA, 0xBB, 0xCC, 0xDD]))


def with_unknown_fields(message, first_number):
    """Returns a copy of `message` that also carries `unknown_fields(first_number)`."""
    copy = type(message)()
    copy.ParseFromString(message.SerializeToString() + unknown_fields(first_number))
    return copy


def length_delimited(field_number, payload):
    """Frames `payload` (serialized message bytes) as one length-delimited field."""
    return varint(field_number << 3 | 2) + varint(len(payload)) + payload


def parse_server(data):
    """Parses `data` with api_pb2 as a ServerOriginatedMessage."""
    message = api_pb2.ServerOriginatedMessage()
    message.ParseFromString(data)
    return message


def check(condition, description):
    """Stops the script if api_pb2 does not decode a merge fixture as `description` says."""
    if not condition:
        sys.exit(f"api_pb2 check failed: {description}")


def server_message(request_id=None):
    """A new ServerOriginatedMessage, with an id unless it is a notification."""
    message = api_pb2.ServerOriginatedMessage()
    if request_id is not None:
        message.id = request_id
    return message


def session_summary(unique_identifier, title, with_geometry=False):
    """A SessionSummary; `with_geometry` also sets frame and grid_size (not modeled)."""
    summary = api_pb2.SessionSummary(unique_identifier=unique_identifier, title=title)
    if with_geometry:
        summary.frame.origin.x = 0
        summary.frame.origin.y = 0
        summary.frame.size.width = 640
        summary.frame.size.height = 480
        summary.grid_size.width = 80
        summary.grid_size.height = 24
    return summary
    # End of def session_summary()


def request_fixtures():
    """Every request fixture: file name to bytes.

    The create-tab fixtures with a command go through Window.async_create(command=...), which
    builds the custom-command profile properties itself. (rpc.async_create_tab's own `command`
    argument fails with a TypeError in module 2.11, so it is not used.) The launch fixture passes
    the same kind of LocalWriteOnlyProfile, plus close-on-end, the way
    Window.async_create_tab(profile_customizations=...) hands it to rpc.async_create_tab.
    """
    lwop = iterm2.profile.LocalWriteOnlyProfile()
    lwop.set_use_custom_command(iterm2.profile.Profile.USE_CUSTOM_COMMAND_ENABLED)
    lwop.set_command(LAUNCH_COMMAND)
    lwop.set_close_sessions_on_end(True)
    return {
        "list-sessions-request.bin": module_request(
            1, lambda c: iterm2.rpc.async_list_sessions(c)),
        "create-tab-request-command.bin": module_request(
            2, lambda c: iterm2.Window.async_create(c, profile=PROFILE_1,
                                                    command="/usr/bin/true")),
        "create-tab-request-launch.bin": module_request(
            (1 << 40) + 5,
            lambda c: iterm2.rpc.async_create_tab(c, profile=PROFILE_1, window=WINDOW_1,
                                                  index=0,
                                                  profile_customizations=lwop.values)),
        "create-tab-request-escaping.bin": module_request(
            3, lambda c: iterm2.Window.async_create(c, command=ESCAPING_COMMAND)),
        "activate-request-session.bin": module_request(
            4, lambda c: iterm2.rpc.async_activate(c, True, True, True, session_id=SESSION_1)),
        "activate-request-tab.bin": module_request(
            5, lambda c: iterm2.rpc.async_activate(c, False, True, False, tab_id="7")),
        "activate-request-window.bin": module_request(
            6, lambda c: iterm2.rpc.async_activate(c, False, False, True, window_id=WINDOW_1)),
        "activate-request-app.bin": module_request(
            7, lambda c: iterm2.rpc.async_activate(
                c, False, False, False,
                activate_app_opts=[iterm2.rpc.ACTIVATE_RAISE_ALL_WINDOWS,
                                   iterm2.rpc.ACTIVATE_IGNORING_OTHER_APPS])),
        "list-profiles-request-all.bin": module_request(
            8, lambda c: iterm2.rpc.async_list_profiles(c, None, None)),
        "list-profiles-request-filtered.bin": module_request(
            9, lambda c: iterm2.rpc.async_list_profiles(c, [GUID_1, GUID_2], ["Guid", "Name"])),
        "tmux-list-connections-request.bin": module_request(
            10, lambda c: iterm2.rpc.async_rpc_list_tmux_connections(c)),
        "tmux-send-command-request.bin": module_request(
            11, lambda c: iterm2.rpc.async_rpc_send_tmux_command(
                c, CONNECTION_1, "display-message -p '#{pid}'")),
        "close-request-sessions.bin": module_request(
            12, lambda c: iterm2.rpc.async_close(c, sessions=[SESSION_1, SESSION_2], force=True)),
        "close-request-windows.bin": module_request(
            13, lambda c: iterm2.rpc.async_close(c, windows=[WINDOW_1], force=False)),
        "set-property-request-bury.bin": module_request(
            20, lambda c: buried_session(c).async_set_buried(True)),
        "set-property-request-unbury.bin": module_request(
            21, lambda c: buried_session(c).async_set_buried(False)),
        "get-property-request-buried.bin": module_request(
            22, lambda c: iterm2.rpc.async_get_property(c, "buried", session_id=SESSION_1)),
        "set-property-request-window.bin": module_request(
            23, lambda c: iterm2.rpc.async_set_property(
                c, "fixture-name", json.dumps("fixture-value"), window_id=WINDOW_1)),
        "get-property-request-window.bin": module_request(
            24, lambda c: iterm2.rpc.async_get_property(c, "fixture-name", window_id=WINDOW_1)),
    }
    # End of def request_fixtures()


def buried_session(connection):
    """The module's Session for SESSION_1 built from a buried session's summary (the way the module
    builds the sessions of ListSessionsResponse.buried_sessions), so its async_set_buried makes
    exactly the request the module sends."""
    return iterm2.Session(connection, None, api_pb2.SessionSummary(unique_identifier=SESSION_1))


def list_sessions_response():
    """Two windows: a plain tab with nested splits, a tmux tab with a minimized session, plus
    a buried session; geometry fields and unknown fields of every wire type are mixed in."""
    message = server_message(1)
    response = message.list_sessions_response

    window = response.windows.add()
    window.window_id = WINDOW_1
    window.number = 0
    window.frame.size.width = 1280
    window.frame.size.height = 800

    plain = window.tabs.add()
    plain.tab_id = "1"
    plain.root.vertical = False
    plain.root.links.add().session.CopyFrom(with_unknown_fields(
        session_summary(SESSION_1, "fixture-title-1", with_geometry=True), 900))
    nested = plain.root.links.add().node
    nested.vertical = True
    nested.links.add().session.CopyFrom(session_summary(SESSION_2, "fixture-title-2"))
    nested.links.add().session.CopyFrom(session_summary(SESSION_3, "fixture-title-3"))

    tmux = window.tabs.add()
    tmux.tab_id = "2"
    tmux.tmux_window_id = "3"
    tmux.tmux_connection_id = CONNECTION_1
    tmux.root.vertical = True
    tmux.root.links.add().session.CopyFrom(session_summary(SESSION_4, "fixture-title-4"))
    tmux.minimized_sessions.add().CopyFrom(session_summary(SESSION_5, "fixture-title-5"))
    window.tabs[1].CopyFrom(with_unknown_fields(tmux, 910))

    second = response.windows.add()
    second.window_id = WINDOW_2
    second.number = 1
    only = second.tabs.add()
    only.tab_id = "3"
    only.root.links.add().session.CopyFrom(session_summary(SESSION_6, "fixture-title-6 \u00fc"))

    response.buried_sessions.add().CopyFrom(session_summary(SESSION_7, "fixture-title-7"))
    # Unknown top-level fields before the id prove the envelope skips them and keeps going.
    return unknown_fields(920) + message.SerializeToString()
    # End of def list_sessions_response()


def response_fixtures():
    """Every response fixture: file name to bytes."""
    fixtures = {"list-sessions-response.bin": list_sessions_response()}

    message = server_message(2)
    message.create_tab_response.status = api_pb2.CreateTabResponse.Status.Value("OK")
    message.create_tab_response.window_id = WINDOW_1
    message.create_tab_response.tab_id = 7
    message.create_tab_response.session_id = SESSION_1
    fixtures["create-tab-response-ok.bin"] = message.SerializeToString()

    message = server_message(3)
    message.create_tab_response.status = (
        api_pb2.CreateTabResponse.Status.Value("INVALID_PROFILE_NAME"))
    fixtures["create-tab-response-invalid-profile.bin"] = message.SerializeToString()

    message = server_message(4)
    message.activate_response.status = api_pb2.ActivateResponse.Status.Value("OK")
    fixtures["activate-response-ok.bin"] = message.SerializeToString()

    message = server_message(5)
    message.activate_response.status = api_pb2.ActivateResponse.Status.Value("BAD_IDENTIFIER")
    fixtures["activate-response-bad-identifier.bin"] = message.SerializeToString()

    message = server_message(9)
    first = message.list_profiles_response.profiles.add()
    first.properties.add(key="Guid", json_value=f'"{GUID_1}"')
    first.properties.add(key="Name", json_value='"fixture-profile-1"')
    first.properties.add(key="Custom Command", json_value='"No"')
    first.properties.add(key="Close Sessions On End", json_value="true")
    second = message.list_profiles_response.profiles.add()
    second.properties.add(key="Name", json_value='"fixture \\"quoted\\" \\u00fc"')
    second.properties.add(key="Guid", json_value=f'"{GUID_2}"')
    fixtures["list-profiles-response.bin"] = message.SerializeToString()

    message = server_message(10)
    tmux = message.tmux_response
    tmux.status = api_pb2.TmuxResponse.Status.Value("OK")
    tmux.list_connections.connections.add(
        connection_id=CONNECTION_1, owning_session_id=SESSION_4)
    tmux.list_connections.connections.add().CopyFrom(with_unknown_fields(
        api_pb2.TmuxResponse.ListConnections.Connection(
            connection_id=CONNECTION_2, owning_session_id=SESSION_6), 930))
    fixtures["tmux-list-connections-response.bin"] = message.SerializeToString()

    message = server_message(11)
    message.tmux_response.status = api_pb2.TmuxResponse.Status.Value("OK")
    message.tmux_response.send_command.output = "4242"
    fixtures["tmux-send-command-response.bin"] = message.SerializeToString()

    message = server_message(12)
    message.tmux_response.status = api_pb2.TmuxResponse.Status.Value("INVALID_CONNECTION_ID")
    fixtures["tmux-response-invalid-connection.bin"] = message.SerializeToString()

    message = server_message(13)
    message.error = "fixture-error-1"
    fixtures["error-response.bin"] = message.SerializeToString()

    message = server_message(14)
    message.variable_response.status = api_pb2.VariableResponse.Status.Value("OK")
    message.variable_response.values.append('"fixture-value-1"')
    fixtures["variable-response-unsupported.bin"] = message.SerializeToString()

    message = server_message()
    message.notification.SetInParent()
    fixtures["notification-unsupported.bin"] = message.SerializeToString()

    message = server_message(15)
    for name in ("OK", "NOT_FOUND", "USER_DECLINED"):
        message.close_response.statuses.append(api_pb2.CloseResponse.Status.Value(name))
    fixtures["close-response.bin"] = message.SerializeToString()

    # The same statuses as one packed run (field 1, wire type 2), which every protobuf parser
    # accepts for a repeated enum even though iTerm2 writes them unpacked.
    packed = varint(1 << 3 | 0) + varint(15) + length_delimited(
        131, length_delimited(1, bytes([0, 1, 2])))
    parsed = parse_server(packed)
    check(list(parsed.close_response.statuses) == [0, 1, 2], "packed close statuses parse")
    fixtures["close-response-packed.bin"] = packed

    message = server_message(20)
    message.set_property_response.status = api_pb2.SetPropertyResponse.Status.Value("OK")
    fixtures["set-property-response-ok.bin"] = message.SerializeToString()

    message = server_message(21)
    message.set_property_response.status = (
        api_pb2.SetPropertyResponse.Status.Value("INVALID_TARGET"))
    fixtures["set-property-response-invalid-target.bin"] = message.SerializeToString()

    message = server_message(22)
    message.get_property_response.status = api_pb2.GetPropertyResponse.Status.Value("OK")
    message.get_property_response.json_value = json.dumps(True)
    fixtures["get-property-response-buried.bin"] = message.SerializeToString()

    message = server_message(23)
    message.get_property_response.status = (
        api_pb2.GetPropertyResponse.Status.Value("INVALID_TARGET"))
    fixtures["get-property-response-invalid-target.bin"] = message.SerializeToString()
    return fixtures
    # End of def response_fixtures()


def link(session=None, node=None):
    """A SplitTreeLink holding `session` (a SessionSummary) or `node` (a SplitTreeNode)."""
    result = api_pb2.SplitTreeNode.SplitTreeLink()
    if session is not None:
        result.session.CopyFrom(session)
    if node is not None:
        result.node.CopyFrom(node)
    return result


def split_list_sessions_response():
    """A list-sessions response whose singular embedded messages arrive in several pieces.

    The response (106) arrives twice; its first window's only tab carries `root` twice; in the
    second root, one link's `node` and another link's `session` arrive twice each, and a fourth
    link switches from `node` to `session` (the node is dropped). Returns the bytes and the
    unsplit message api_pb2 must parse them to.
    """
    sessions = [SESSION_1, SESSION_2, SESSION_3, SESSION_4, SESSION_5, SESSION_6, SESSION_7]
    summary = {n: session_summary(sessions[n - 1], f"fixture-title-{n}") for n in range(1, 8)}
    first_root = api_pb2.SplitTreeNode(vertical=False, links=[link(session=summary[1])])
    second_root = (
        api_pb2.SplitTreeNode(vertical=True).SerializeToString()
        + length_delimited(2, link(node=api_pb2.SplitTreeNode(vertical=True)).SerializeToString()
                           + link(node=api_pb2.SplitTreeNode(links=[link(session=summary[2])]))
                           .SerializeToString())
        + length_delimited(2, link(session=api_pb2.SessionSummary(unique_identifier=SESSION_3))
                           .SerializeToString()
                           + link(session=api_pb2.SessionSummary(title="fixture-title-3"))
                           .SerializeToString())
        + length_delimited(2, link(node=api_pb2.SplitTreeNode(links=[link(session=summary[7])]))
                           .SerializeToString()
                           + link(session=summary[6]).SerializeToString()))
    tab = (api_pb2.ListSessionsResponse.Tab(tab_id="1", root=first_root).SerializeToString()
           + length_delimited(3, second_root)
           + api_pb2.ListSessionsResponse.Tab(tmux_window_id="3").SerializeToString())
    window = (api_pb2.ListSessionsResponse.Window(window_id=WINDOW_1).SerializeToString()
              + length_delimited(1, tab))
    second_part = api_pb2.ListSessionsResponse(buried_sessions=[summary[5]])
    second_window = second_part.windows.add(window_id=WINDOW_2)
    second_window.tabs.add(tab_id="2").root.links.add().session.CopyFrom(summary[4])
    data = (server_message(18).SerializeToString()
            + length_delimited(106, length_delimited(1, window))
            + length_delimited(106, second_part.SerializeToString()))

    expected = server_message(18)
    merged_window = expected.list_sessions_response.windows.add(window_id=WINDOW_1)
    merged_tab = merged_window.tabs.add(tab_id="1", tmux_window_id="3")
    merged_tab.root.vertical = True
    merged_tab.root.links.add().session.CopyFrom(summary[1])
    merged_node = merged_tab.root.links.add().node
    merged_node.vertical = True
    merged_node.links.add().session.CopyFrom(summary[2])
    merged_tab.root.links.add().session.CopyFrom(summary[3])
    merged_tab.root.links.add().session.CopyFrom(summary[6])
    expected.list_sessions_response.windows.add().CopyFrom(second_window)
    expected.list_sessions_response.buried_sessions.add().CopyFrom(summary[5])
    return data, expected
    # End of def split_list_sessions_response()


def merge_fixtures():
    """Every merge fixture: file name to bytes. Each is checked against api_pb2's decoding."""
    fixtures = {}

    # Python re-serializes unknown fields after the known ones, so the unknown top-level fields
    # that list-sessions-response.bin carries before the id end up after the response.
    original = list_sessions_response()
    reserialized = parse_server(original).SerializeToString()
    check(reserialized.endswith(unknown_fields(920)) and not reserialized.startswith(
        unknown_fields(920)), "re-serializing moves unknown top-level fields to the end")
    check(parse_server(reserialized).list_sessions_response
          == parse_server(original).list_sessions_response,
          "re-serializing keeps the list-sessions response")
    fixtures["list-sessions-response-reserialized.bin"] = reserialized

    # Unknown fields (not in the proto) before and after a response, plus a member of the oneof
    # (variable_response, 115) with the wrong wire type, which protobuf treats as unknown.
    message = server_message(15)
    message.create_tab_response.window_id = WINDOW_1
    message.create_tab_response.tab_id = 7
    message.create_tab_response.session_id = SESSION_1
    data = (unknown_fields(150) + message.SerializeToString() + unknown_fields(2000)
            + varint(115 << 3 | 0) + varint(1))
    decoded = parse_server(data)
    check(decoded.WhichOneof("submessage") == "create_tab_response"
          and decoded.create_tab_response == message.create_tab_response and decoded.id == 15,
          "unknown fields around a response leave it alone")
    fixtures["create-tab-response-unknown-fields.bin"] = data

    # An unmodeled member of the oneof after a modeled one replaces it.
    variable = api_pb2.ServerOriginatedMessage()
    variable.variable_response.status = api_pb2.VariableResponse.Status.Value("OK")
    variable.variable_response.values.append('"fixture-value-1"')
    modeled = server_message(16)
    modeled.create_tab_response.CopyFrom(message.create_tab_response)
    data = modeled.SerializeToString() + variable.SerializeToString()
    decoded = parse_server(data)
    check(decoded.WhichOneof("submessage") == "variable_response" and decoded.id == 16,
          "an unmodeled member after a modeled one wins")
    fixtures["create-tab-response-then-unmodeled.bin"] = data

    # A modeled member after an unmodeled one wins, and starts afresh: the first create-tab
    # response (before the unmodeled member) contributes nothing.
    first = server_message(17)
    first.create_tab_response.status = (
        api_pb2.CreateTabResponse.Status.Value("INVALID_PROFILE_NAME"))
    first.create_tab_response.window_id = WINDOW_2
    last = api_pb2.ServerOriginatedMessage()
    last.create_tab_response.CopyFrom(message.create_tab_response)
    data = first.SerializeToString() + variable.SerializeToString() + last.SerializeToString()
    expected = server_message(17)
    expected.create_tab_response.CopyFrom(message.create_tab_response)
    check(parse_server(data) == expected, "a modeled member after an unmodeled one wins afresh")
    fixtures["create-tab-response-after-unmodeled.bin"] = data

    # The same response twice: the second, empty occurrence keeps the first one's status.
    first = server_message(1)
    first.activate_response.status = api_pb2.ActivateResponse.Status.Value("BAD_IDENTIFIER")
    second = api_pb2.ServerOriginatedMessage()
    second.activate_response.SetInParent()
    data = first.SerializeToString() + second.SerializeToString()
    check(data == bytes.fromhex("08019207020801920700"), "activate split has the reviewed bytes")
    check(parse_server(data) == first, "an empty second occurrence keeps the status")
    fixtures["activate-response-split.bin"] = data

    data, expected = split_list_sessions_response()
    check(parse_server(data) == expected, "split list-sessions pieces merge")
    fixtures["list-sessions-response-split.bin"] = data

    # The tmux payload oneof: an empty second send_command keeps the first one's output.
    first = server_message(19)
    first.tmux_response.send_command.output = "4242"
    second = api_pb2.ServerOriginatedMessage()
    second.tmux_response.send_command.SetInParent()
    data = first.SerializeToString() + second.SerializeToString()
    check(parse_server(data) == first, "an empty second send_command keeps the output")
    fixtures["tmux-send-command-response-split.bin"] = data
    return fixtures
    # End of def merge_fixtures()


def main():
    """Writes every fixture and checks that each one parses back with api_pb2."""
    os.makedirs(OUTPUT_DIRECTORY, exist_ok=True)
    fixtures = {**request_fixtures(), **response_fixtures(), **merge_fixtures()}
    for name, data in sorted(fixtures.items()):
        kind = (api_pb2.ClientOriginatedMessage if "-request" in name
                else api_pb2.ServerOriginatedMessage)
        kind().ParseFromString(data)
        with open(os.path.join(OUTPUT_DIRECTORY, name), "wb") as file:
            file.write(data)
        print(f"{name}: {len(data)} bytes")
    print(f"Wrote {len(fixtures)} fixtures to {os.path.relpath(OUTPUT_DIRECTORY, os.getcwd())} "
          f"(iterm2 module {iterm2.__version__}).")
    # End of def main()


if __name__ == "__main__":
    main()
