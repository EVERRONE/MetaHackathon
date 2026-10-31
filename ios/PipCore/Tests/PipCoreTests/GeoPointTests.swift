import Foundation
import Testing
@testable import PipCore

/// The phone's location only tells homes and buildings apart.
@Suite struct GeoPointTests {
    let home = GeoPoint(latitude: 51.0543, longitude: 3.7174, accuracy: 30)

    @Test func distancesAreInMetres() {
        // 0.001° of latitude is about 111 m.
        let north = GeoPoint(latitude: 51.0553, longitude: 3.7174, accuracy: 30)
        #expect(abs(home.distance(to: north) - 111) < 2)
        #expect(home.distance(to: home) == 0)
    }

    @Test func theSameHomeEvenWithAPoorFixIndoors() {
        let poor = GeoPoint(latitude: 51.0549, longitude: 3.7180, accuracy: 120)
        #expect(home.couldBeSamePlace(as: poor))
    }

    @Test func anotherTownIsNot() {
        let brussels = GeoPoint(latitude: 50.8503, longitude: 4.3517, accuracy: 20)
        #expect(!home.couldBeSamePlace(as: brussels))
        let streetFurther = GeoPoint(latitude: 51.0580, longitude: 3.7174, accuracy: 20)
        #expect(!home.couldBeSamePlace(as: streetFurther))
    }

    @Test func oldPiecesWithoutALocationStillLoad() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","created":0,"updated":0,"keyframes":[]}"#
        let piece = try JSONDecoder().decode(MapPiece.self, from: Data(json.utf8))
        #expect(piece.location == nil)
        var withPlace = piece
        withPlace.location = home
        let again = try JSONDecoder().decode(MapPiece.self, from: JSONEncoder().encode(withPlace))
        #expect(again.location == home)
    }
}
