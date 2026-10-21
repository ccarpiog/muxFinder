import Foundation

extension ITerm2API {
  /// `ListProfilesRequest`: asks for profiles and their properties.
  public struct ListProfilesRequest: Sendable, Hashable, ProtoEncodable {
    /// `properties` (1): the property keys to return; empty returns every property.
    public var properties: [String]
    /// `guids` (2): the profiles to return; empty returns every profile.
    public var guids: [String]

    /// Creates a request.
    public init(properties: [String] = [], guids: [String] = []) {
      self.properties = properties
      self.guids = guids
    }

    /// Writes every property key, then every GUID (field-number order).
    public func encode(to writer: inout ProtoWriter) {
      for property in properties { writer.writeString(1, property) }
      for guid in guids { writer.writeString(2, guid) }
    }
  } // End of struct ListProfilesRequest

  /// `ListProfilesResponse`.
  public struct ListProfilesResponse: Sendable, Hashable, ProtoDecodable {
    /// `profiles` (1).
    public var profiles: [Profile]

    /// Creates a response.
    public init(profiles: [Profile] = []) {
      self.profiles = profiles
    }

    /// Decodes a response.
    public init(from reader: inout ProtoReader) throws {
      self.init()
      while let field = try reader.nextField() {
        switch (field.number, field.wireType) {
        case (1, .lengthDelimited): profiles.append(try reader.readMessage(Profile.self))
        default: try reader.skip(field.wireType)
        }
      }
    }
  } // End of struct ListProfilesResponse

  /// `ListProfilesResponse.Profile`: a profile's properties as key and JSON text pairs.
  public struct Profile: Sendable, Hashable, ProtoDecodable {
    /// `properties` (1), in iTerm2's order.
    public var properties: [ProfileProperty]

    /// Creates a profile.
    public init(properties: [ProfileProperty] = []) {
      self.properties = properties
    }

    /// The JSON text of the property `key`, or `nil` if absent. If the key repeats, the last
    /// one wins.
    public func jsonValue(forKey key: String) -> String? {
      properties.last { $0.key == key }?.jsonValue
    }

    /// The property `key` decoded as a JSON string, or `nil` if absent or not a string.
    public func stringValue(forKey key: String) -> String? {
      jsonValue(forKey: key).flatMap(ITerm2JSON.decodeString)
    }

    /// The profile's `"Name"`.
    public var name: String? { stringValue(forKey: ProfileProperty.Key.name) }

    /// The profile's `"Guid"`.
    public var guid: String? { stringValue(forKey: ProfileProperty.Key.guid) }

    /// Decodes a profile.
    public init(from reader: inout ProtoReader) throws {
      self.init()
      while let field = try reader.nextField() {
        switch (field.number, field.wireType) {
        case (1, .lengthDelimited):
          properties.append(try reader.readMessage(ProfileProperty.self))
        default: try reader.skip(field.wireType)
        }
      }
    }
  } // End of struct Profile
}
