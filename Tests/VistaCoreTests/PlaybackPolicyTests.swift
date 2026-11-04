import Testing
import VideoToolbox
@testable import VistaMedia
struct PlaybackPolicyTests {
    @Test func ordinaryMacBuildRequiresHardware() {
        #expect(!PlaybackDecodingPolicy.simulatorSoftwareTest)
        let specification=PlaybackDecodingPolicy.decoderSpecification as NSDictionary
        #expect(specification[kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder] as? Bool == true)
    }
}
