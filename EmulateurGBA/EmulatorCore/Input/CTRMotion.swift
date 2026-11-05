//
//  CTRMotion.swift
//  EmulateurGBA
//
//  The 3DS's accelerometer and gyroscope, from the phone's: CoreMotion's
//  device motion, turned to the 3DS's axes and handed to CTRBridge, which the
//  core reads through libretro's sensor interface. Running only while a 3DS
//  game runs (EmulatorSession's start, pause, resume, stop): no sensor is on in
//  the library or the pause menu. Motion data asks no permission on iOS.
//
//  THE AXES are Azahar's own Android frontend's (src/android/app/src/main/jni/
//  ndk_motion.cpp, TransformAxes), which maps a phone held like the 3DS's
//  lower screen:
//
//      3DS    Y+                    phone      Z+
//      on     |                     lying      |
//      table  |                     upright    |
//             |_______ X-                      |_______ X+
//            /                                /
//           Z-                              Y-
//
//  so out.y = in.z, and out.x, out.z from in.x, in.y by the screen's rotation.
//  Android's accelerometer reads the REACTION to gravity (+1 g up, phone flat)
//  and that frontend divides by -g; CoreMotion reads gravity itself (-1 g on
//  z, phone flat), already the opposite sign, so its values in g go through
//  the same mapping as they are. Rotation rates are right-handed in the
//  device's frame on both, radians per second: the same mapping, unsigned.
//

import CoreMotion
import UIKit

final class CTRMotion {
    private let manager = CMMotionManager()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "CTRMotion"
        q.maxConcurrentOperationCount = 1
        return q
    }()
    private weak var bridge: CTRBridge?
    /// The interface orientation, read on the main thread when started and
    /// after each rotation (`orientationDidChange`): the mapping depends on
    /// it. The INTERFACE's, not the device's: the per-game orientation pin and
    /// the system lock both hold the picture still while the phone turns.
    private var rotation = Rotation.portrait

    /// Android's `screen_rotation`: quarter turns counter-clockwise from
    /// portrait.
    enum Rotation: Int {
        case portrait = 0, landscapeHomeRight = 1, portraitUpsideDown = 2, landscapeHomeLeft = 3

        /// Android's ROTATION_90 is the phone turned a quarter counter-
        /// clockwise, its top to the left and its home side on the right,
        /// which UIKit's interface orientation calls `.landscapeRight` ("the
        /// home button on the right side"; the DEVICE orientation calls the
        /// same pose `.landscapeLeft`). Checked by gravity: turned that way,
        /// the phone's x axis points up, gravity reads x = -1, and the case
        /// below gives the 3DS z = -1, a 3DS held upright.
        init(_ orientation: UIInterfaceOrientation) {
            switch orientation {
            case .landscapeRight: self = .landscapeHomeRight
            case .landscapeLeft: self = .landscapeHomeLeft
            case .portraitUpsideDown: self = .portraitUpsideDown
            default: self = .portrait
            }
        }
    }

    init(bridge: CTRBridge) {
        self.bridge = bridge
    }

    deinit { stop() }

    /// The phone's axes (x right, y up the screen, z out of it) to the 3DS's,
    /// for a screen turned `rotation`. `ndk_motion.cpp`'s cases, in order.
    static func transform(_ v: (x: Double, y: Double, z: Double), rotation: Rotation)
        -> (x: Double, y: Double, z: Double) {
        switch rotation {
        case .portrait:           return (-v.x, v.z, v.y)
        case .landscapeHomeRight: return (v.y, v.z, v.x)
        case .portraitUpsideDown: return (v.x, v.z, -v.y)
        case .landscapeHomeLeft:  return (-v.y, v.z, -v.x)
        }
    }

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        orientationDidChange()
        manager.deviceMotionUpdateInterval = 1.0 / 60.0
        manager.startDeviceMotionUpdates(to: queue) { [weak self] motion, _ in
            guard let self, let motion, let bridge = self.bridge else { return }
            let g = motion.gravity, u = motion.userAcceleration, r = motion.rotationRate
            let rotation = self.currentRotation()
            let a = Self.transform((g.x + u.x, g.y + u.y, g.z + u.z), rotation: rotation)
            let w = Self.transform((r.x, r.y, r.z), rotation: rotation)
            bridge.setAccelerationX(Float(a.x), y: Float(a.y), z: Float(a.z),
                                    rotationX: Float(w.x), y: Float(w.y), z: Float(w.z))
        }
    }

    func stop() {
        if manager.isDeviceMotionActive { manager.stopDeviceMotionUpdates() }
    }

    private let rotationLock = NSLock()

    private func currentRotation() -> Rotation {
        rotationLock.lock(); defer { rotationLock.unlock() }
        return rotation
    }

    /// The PHONE's interface orientation. Not whichever scene comes first:
    /// with a television attached, its scene is a window scene too, and the
    /// axes (and the cameras' picture) followed the TV's (audit, 2026-10-20).
    /// The phone's is the application's scene (the TV's has the external
    /// display role). Main thread.
    static var phoneInterfaceOrientation: UIInterfaceOrientation {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let phone = scenes.first { $0.session.role == .windowApplication } ?? scenes.first
        return phone?.interfaceOrientation ?? .portrait
    }

    /// Main thread, after the interface has rotated.
    func orientationDidChange() {
        let orientation = CTRMotion.phoneInterfaceOrientation
        rotationLock.lock(); rotation = Rotation(orientation); rotationLock.unlock()
    }
}
