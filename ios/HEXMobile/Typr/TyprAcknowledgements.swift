/// Typr's entries in Settings › Acknowledgements.
@MainActor
enum TyprAcknowledgements {
    static let entries: [AcknowledgementsView.Entry] = [
        AcknowledgementsView.Entry(
            title: "Orukeet",
            body: """
            Settings › Typr › Orukeet downloads Orukeet by Oruk AI (huggingface.co/oruk/orukeet, \
            revision 419d7f7), an adaptation of NVIDIA's Parakeet TDT 0.6B v3 \
            (huggingface.co/nvidia/parakeet-tdt-0.6b-v3, Creative Commons Attribution 4.0 \
            International), licensed under Creative Commons Attribution-ShareAlike 4.0 \
            International (creativecommons.org/licenses/by-sa/4.0). Hex uses Oruk AI's iOS Core \
            ML archive with an 8-bit encoder unchanged and compiles it on the iPhone; it does not \
            ship the weights.
            """
        ),
    ]
}
