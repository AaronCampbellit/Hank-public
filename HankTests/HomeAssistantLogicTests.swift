import XCTest
@testable import Hank

final class HomeAssistantLogicTests: XCTestCase {
    func testSupportedEntityActionMapping() {
        let toggleEntity = HAEntitySummary(
            entityID: "light.office",
            friendlyName: "Office",
            domain: "light",
            icon: nil,
            controlStyle: .toggle,
            unitOfMeasurement: nil,
            deviceClass: nil,
            supportsBrightness: true
        )
        let offState = HAEntityState(
            entityID: "light.office",
            state: "off",
            friendlyName: "Office",
            icon: nil,
            unitOfMeasurement: nil,
            deviceClass: nil,
            supportedColorModes: ["brightness"],
            brightness: 64
        )
        let onState = HAEntityState(
            entityID: "light.office",
            state: "on",
            friendlyName: "Office",
            icon: nil,
            unitOfMeasurement: nil,
            deviceClass: nil,
            supportedColorModes: ["brightness"],
            brightness: 200
        )

        XCTAssertEqual(
            HomeAssistantActionResolver.serviceCall(for: toggleEntity, state: offState),
            HomeAssistantServiceCall(domain: "light", service: "turn_on", payload: .entity(entityID: "light.office"))
        )
        XCTAssertEqual(
            HomeAssistantActionResolver.serviceCall(for: toggleEntity, state: onState),
            HomeAssistantServiceCall(domain: "light", service: "turn_off", payload: .entity(entityID: "light.office"))
        )

        let buttonEntity = HAEntitySummary(
            entityID: "button.garage",
            friendlyName: "Garage",
            domain: "button",
            icon: nil,
            controlStyle: .press,
            unitOfMeasurement: nil,
            deviceClass: nil,
            supportsBrightness: false
        )

        XCTAssertEqual(
            HomeAssistantActionResolver.serviceCall(for: buttonEntity, state: nil),
            HomeAssistantServiceCall(domain: "button", service: "press", payload: .entity(entityID: "button.garage"))
        )
    }

    func testSensorEntitiesAreReadOnly() {
        let sensorEntity = HAEntitySummary(
            entityID: "sensor.living_room_temperature",
            friendlyName: "Living Room Temperature",
            domain: "sensor",
            icon: nil,
            controlStyle: .readOnly,
            unitOfMeasurement: "°F",
            deviceClass: "temperature",
            supportsBrightness: false
        )

        XCTAssertNil(HomeAssistantActionResolver.serviceCall(for: sensorEntity, state: nil))
    }

    func testDashboardSupportsDomainsThatFitCurrentTileControls() {
        let expectedDomains: [String: HomeAssistantControlStyle] = [
            "light": .toggle,
            "switch": .toggle,
            "input_boolean": .toggle,
            "fan": .toggle,
            "automation": .toggle,
            "humidifier": .toggle,
            "media_player": .toggle,
            "remote": .toggle,
            "siren": .toggle,
            "cover": .toggle,
            "valve": .toggle,
            "lock": .toggle,
            "script": .activate,
            "scene": .activate,
            "button": .press,
            "input_button": .press,
            "sensor": .readOnly,
            "binary_sensor": .readOnly
        ]

        for (domain, controlStyle) in expectedDomains {
            XCTAssertTrue(HomeAssistantActionResolver.supports(entityID: "\(domain).sample"), domain)
            XCTAssertEqual(HomeAssistantActionResolver.controlStyle(for: domain), controlStyle, domain)
        }
    }

    func testDashboardRejectsDomainsThatNeedSpecializedControls() {
        let unsupportedDomains = [
            "alarm_control_panel",
            "camera",
            "climate",
            "device_tracker",
            "input_number",
            "input_select",
            "lawn_mower",
            "number",
            "person",
            "select",
            "vacuum"
        ]

        for domain in unsupportedDomains {
            XCTAssertFalse(HomeAssistantActionResolver.supports(entityID: "\(domain).sample"), domain)
        }
    }

    func testAdditionalTileCompatibleActionMappings() {
        let inputButton = HAEntitySummary(
            entityID: "input_button.doorbell",
            friendlyName: "Doorbell",
            domain: "input_button",
            icon: nil,
            controlStyle: .press,
            unitOfMeasurement: nil,
            deviceClass: nil,
            supportsBrightness: false
        )
        let playingMedia = HAEntitySummary(
            entityID: "media_player.living_room",
            friendlyName: "Living Room",
            domain: "media_player",
            icon: nil,
            controlStyle: .toggle,
            unitOfMeasurement: nil,
            deviceClass: nil,
            supportsBrightness: false
        )
        let cover = HAEntitySummary(
            entityID: "cover.garage_door",
            friendlyName: "Garage Door",
            domain: "cover",
            icon: nil,
            controlStyle: .toggle,
            unitOfMeasurement: nil,
            deviceClass: "garage",
            supportsBrightness: false
        )
        let valve = HAEntitySummary(
            entityID: "valve.water_main",
            friendlyName: "Water Main",
            domain: "valve",
            icon: nil,
            controlStyle: .toggle,
            unitOfMeasurement: nil,
            deviceClass: "water",
            supportsBrightness: false
        )
        let playingState = HAEntityState(
            entityID: "media_player.living_room",
            state: "playing",
            friendlyName: "Living Room",
            icon: nil,
            unitOfMeasurement: nil,
            deviceClass: nil,
            supportedColorModes: [],
            brightness: nil
        )

        XCTAssertEqual(
            HomeAssistantActionResolver.serviceCall(for: inputButton, state: nil),
            HomeAssistantServiceCall(domain: "input_button", service: "press", payload: .entity(entityID: "input_button.doorbell"))
        )
        XCTAssertEqual(
            HomeAssistantActionResolver.serviceCall(for: playingMedia, state: playingState),
            HomeAssistantServiceCall(domain: "media_player", service: "turn_off", payload: .entity(entityID: "media_player.living_room"))
        )
        XCTAssertEqual(
            HomeAssistantActionResolver.serviceCall(for: cover, state: nil),
            HomeAssistantServiceCall(domain: "cover", service: "toggle", payload: .entity(entityID: "cover.garage_door"))
        )
        XCTAssertEqual(
            HomeAssistantActionResolver.serviceCall(for: valve, state: nil),
            HomeAssistantServiceCall(domain: "valve", service: "toggle", payload: .entity(entityID: "valve.water_main"))
        )
    }

    func testLockEntityActionMapping() {
        let lockEntity = HAEntitySummary(
            entityID: "lock.front_door",
            friendlyName: "Front Door",
            domain: "lock",
            icon: nil,
            controlStyle: .toggle,
            unitOfMeasurement: nil,
            deviceClass: nil,
            supportsBrightness: false
        )
        let lockedState = HAEntityState(
            entityID: "lock.front_door",
            state: "locked",
            friendlyName: "Front Door",
            icon: nil,
            unitOfMeasurement: nil,
            deviceClass: nil,
            supportedColorModes: [],
            brightness: nil
        )
        let unlockedState = HAEntityState(
            entityID: "lock.front_door",
            state: "unlocked",
            friendlyName: "Front Door",
            icon: nil,
            unitOfMeasurement: nil,
            deviceClass: nil,
            supportedColorModes: [],
            brightness: nil
        )

        XCTAssertEqual(
            HomeAssistantActionResolver.serviceCall(for: lockEntity, state: lockedState),
            HomeAssistantServiceCall(domain: "lock", service: "unlock", payload: .entity(entityID: "lock.front_door"))
        )
        XCTAssertEqual(
            HomeAssistantActionResolver.serviceCall(for: lockEntity, state: unlockedState),
            HomeAssistantServiceCall(domain: "lock", service: "lock", payload: .entity(entityID: "lock.front_door"))
        )
    }

    func testBrightnessActionMapping() {
        let dimmableLight = HAEntitySummary(
            entityID: "light.kitchen",
            friendlyName: "Kitchen",
            domain: "light",
            icon: nil,
            controlStyle: .toggle,
            unitOfMeasurement: nil,
            deviceClass: nil,
            supportsBrightness: true
        )

        XCTAssertEqual(
            HomeAssistantActionResolver.brightnessServiceCall(for: dimmableLight, brightnessPercent: 42),
            HomeAssistantServiceCall(
                domain: "light",
                service: "turn_on",
                payload: .lightBrightness(entityID: "light.kitchen", brightnessPercent: 42)
            )
        )
    }

    func testEntitySearchMatchesAllQueryTermsAcrossNameAndEntityID() {
        let garageMain = HAEntitySummary(
            entityID: "light.garage_main",
            friendlyName: "Garage Main",
            domain: "light",
            icon: nil,
            controlStyle: .toggle,
            unitOfMeasurement: nil,
            deviceClass: nil,
            supportsBrightness: true
        )
        let garageDoor = HAEntitySummary(
            entityID: "cover.garage_door",
            friendlyName: "Garage Door",
            domain: "cover",
            icon: nil,
            controlStyle: .toggle,
            unitOfMeasurement: nil,
            deviceClass: nil,
            supportsBrightness: false
        )
        let patioLights = HAEntitySummary(
            entityID: "light.patio",
            friendlyName: "Patio Lights",
            domain: "light",
            icon: nil,
            controlStyle: .toggle,
            unitOfMeasurement: nil,
            deviceClass: nil,
            supportsBrightness: true
        )

        XCTAssertNotNil(DashboardStore.entitySearchScore(for: garageMain, query: "garage lights"))
        XCTAssertNil(DashboardStore.entitySearchScore(for: garageDoor, query: "garage lights"))
        XCTAssertNil(DashboardStore.entitySearchScore(for: patioLights, query: "garage lights"))
    }

    func testEntitySearchMatchesPluralAndSingularLightTerms() {
        let garageLights = HAEntitySummary(
            entityID: "light.garage_lights",
            friendlyName: "Garage Lights",
            domain: "light",
            icon: nil,
            controlStyle: .toggle,
            unitOfMeasurement: nil,
            deviceClass: nil,
            supportsBrightness: true
        )

        XCTAssertNotNil(DashboardStore.entitySearchScore(for: garageLights, query: "garage light"))
        XCTAssertNotNil(DashboardStore.entitySearchScore(for: garageLights, query: "garage lights"))
    }

    func testDashboardCreatesSelectableEntityFromNewStateEvent() {
        let newState = HAEntityState(
            entityID: "light.new_lamp",
            state: "off",
            friendlyName: "New Lamp",
            icon: "mdi:lamp",
            unitOfMeasurement: nil,
            deviceClass: nil,
            supportedColorModes: ["brightness"],
            brightness: 0
        )

        let entity = DashboardStore.entitySummary(from: newState)

        XCTAssertEqual(entity?.entityID, "light.new_lamp")
        XCTAssertEqual(entity?.suggestedLabel, "New Lamp")
        XCTAssertEqual(entity?.domain, "light")
        XCTAssertEqual(entity?.controlStyle, .toggle)
        XCTAssertTrue(entity?.supportsBrightness ?? false)
    }

    func testDashboardCreatesSelectableLockEntityFromNewStateEvent() {
        let newState = HAEntityState(
            entityID: "lock.front_door",
            state: "locked",
            friendlyName: "Front Door",
            icon: "mdi:lock",
            unitOfMeasurement: nil,
            deviceClass: nil,
            supportedColorModes: [],
            brightness: nil
        )

        let entity = DashboardStore.entitySummary(from: newState)

        XCTAssertEqual(entity?.entityID, "lock.front_door")
        XCTAssertEqual(entity?.suggestedLabel, "Front Door")
        XCTAssertEqual(entity?.domain, "lock")
        XCTAssertEqual(entity?.controlStyle, .toggle)
        XCTAssertFalse(entity?.supportsBrightness ?? true)
    }

    func testDashboardIgnoresUnsupportedNewStateEvent() {
        let unsupportedState = HAEntityState(
            entityID: "person.aaron",
            state: "home",
            friendlyName: "Aaron",
            icon: nil,
            unitOfMeasurement: nil,
            deviceClass: nil,
            supportedColorModes: [],
            brightness: nil
        )

        XCTAssertNil(DashboardStore.entitySummary(from: unsupportedState))
    }
}
