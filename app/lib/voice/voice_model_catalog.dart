/// Streaming models feed the live partials; offline models re-transcribe the
/// whole utterance once capture stops and their text replaces the partials.
enum VoiceModelRole { live, offline }

class VoiceModelFile {
  const VoiceModelFile(this.name, this.bytes, this.sha256);
  final String name;
  final int bytes;
  final String sha256;
}

class VoiceModel {
  const VoiceModel({
    required this.id,
    required this.label,
    required this.role,
    required this.language,
    required this.licence,
    required this.repo,
    required this.revision,
    required this.encoder,
    required this.decoder,
    required this.joiner,
    required this.tokens,
  });
  final String id;
  final String label;
  final VoiceModelRole role;

  /// BCP 47 tag of the speech the model was measured on.
  final String language;
  final String licence;

  /// Hugging Face repo. Downloads resolve at [revision], never a branch, so
  /// a force-pushed repo cannot change what an install fetches; the per-file
  /// sha256 is still checked because the host is not ours.
  final String repo;
  final String revision;
  final VoiceModelFile encoder;
  final VoiceModelFile decoder;
  final VoiceModelFile joiner;
  final VoiceModelFile tokens;

  List<VoiceModelFile> get files => [encoder, decoder, joiner, tokens];
  int get bytes => files.fold(0, (sum, f) => sum + f.bytes);
  Uri url(VoiceModelFile file) =>
      Uri.https('huggingface.co', '/$repo/resolve/$revision/${file.name}');
}

const krokoEn = VoiceModel(
  id: 'kroko-en-2025-08-06',
  label: 'Kroko (English, live)',
  role: VoiceModelRole.live,
  language: 'en',
  licence: 'CC-BY-SA-4.0',
  repo: 'csukuangfj/sherpa-onnx-streaming-zipformer-en-kroko-2025-08-06',
  revision: '572aaf4e2e0c603c3fc2a574d096e755a178faa1',
  encoder: VoiceModelFile(
    'encoder.onnx',
    70092599,
    'd4881c57449d581e0770fd53fa66c2fdc6cd167d92ece7c715e603defc96d9d4',
  ),
  decoder: VoiceModelFile(
    'decoder.onnx',
    617488,
    '455ba38466fce8d5a57e7db68a323b684079ca4d9e1dd93a740d9b2429aae3b1',
  ),
  joiner: VoiceModelFile(
    'joiner.onnx',
    336817,
    'd406f616736350e2a7df3e39398b78eb2fc1a2ca6973a19d3853fa3227e25b52',
  ),
  tokens: VoiceModelFile(
    'tokens.txt',
    6310,
    '396dbeb5f4858875690716084f54e90d339679d0ba3e6b5b584f3d7589254d2d',
  ),
);

const parakeetV2 = VoiceModel(
  id: 'parakeet-tdt-0.6b-v2-int8',
  label: 'Parakeet TDT 0.6B v2 (English)',
  role: VoiceModelRole.offline,
  language: 'en',
  licence: 'CC-BY-4.0',
  repo: 'csukuangfj/sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8',
  revision: '1ab9323565ddb038682214b292f588070a538ce2',
  encoder: VoiceModelFile(
    'encoder.int8.onnx',
    652184296,
    'a32b12d17bbbc309d0686fbbcc2987b5e9b8333a7da83fa6b089f0a2acd651ab',
  ),
  decoder: VoiceModelFile(
    'decoder.int8.onnx',
    7257753,
    'b6bb64963457237b900e496ee9994b59294526439fbcc1fecf705b31a15c6b4e',
  ),
  joiner: VoiceModelFile(
    'joiner.int8.onnx',
    1739080,
    '7946164367946e7f9f29a122407c3252b680dbae9a51343eb2488d057c3c43d2',
  ),
  tokens: VoiceModelFile(
    'tokens.txt',
    9384,
    'ec182b70dd42113aff6c5372c75cac58c952443eb22322f57bbd7f53977d497d',
  ),
);

// TODO(bharath): repoint every entry at our own Hugging Face org. The upstream
// int8 repo for this model is empty, so this one is a third-party copy whose
// hashes match the upstream release tarball.
const parakeet110m = VoiceModel(
  id: 'parakeet-tdt-110m-en-int8',
  label: 'Parakeet TDT 110M (English, small)',
  role: VoiceModelRole.offline,
  language: 'en',
  licence: 'CC-BY-4.0',
  repo: 'punitd/sherpa-onnx-nemo-parakeet_tdt_transducer_110m-en-36000-int8',
  revision: '66a4fa70643dc7ce25c9b38b2f87e1b35ddad33d',
  encoder: VoiceModelFile(
    'encoder.int8.onnx',
    131113202,
    '0f35509ddeb9b39002fb077d979a9fe74f06eb0bc4dd5c34f512f82e5111d657',
  ),
  decoder: VoiceModelFile(
    'decoder.int8.onnx',
    3955863,
    'f7c331c5504c2e593c76ed22b728e3f554af6c4a383dde862e719ced08b1da19',
  ),
  joiner: VoiceModelFile(
    'joiner.int8.onnx',
    1411403,
    'bf7dff69e9f2cdbe9943d70da358f38b361c115ba0105bae7e908e0d6ec782f6',
  ),
  tokens: VoiceModelFile(
    'tokens.txt',
    9953,
    '450e56bd2f036fe5b6aa821865838cc5aa9d8b0106134ce9a9ba0664abe6cd10',
  ),
);

const voiceModels = [krokoEn, parakeetV2, parakeet110m];
