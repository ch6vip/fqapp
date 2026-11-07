import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'ai_models.dart';

/// The first and only built-in behaviour prompt. Editable copies live in the
/// prompt store; the program-owned protocol below is never editable.
const String kAiDefaultBehaviorPrompt = '''
你是一名严谨、保守的中文小说文字校对员。
你的任务是阅读完整章节，找出明确影响阅读流畅度的基础语言错误，并输出局部替换建议。
只允许修复：
1. 错别字、漏字、重复字。
2. 明确的语法错误、语序错误、句式杂糅。
3. 不自然或错误的词语搭配。
4. 明显的指代错误、否定错误和关联词误用。
5. 明显错误的标点。
6. 使句子难以正常理解的基础表达问题。
严格禁止：
- 文学润色、美化语言。
- 改变作者的叙述风格和人物说话方式。
- 修改没有明显错误的句子。
- 增删剧情、动作、情绪、心理或世界观信息。
- 擅自修改人名、地名、术语和专有名词。
- 删除作者有意使用的重复、停顿或特殊表达。
- 为了让句子更漂亮而扩大修改范围。
校对原则：
宁可漏改，也不要误改。
能够修改一个词，就不要重写整个句子。
只有明确存在问题时才提出修改。
''';

/// Program-owned edit contract. Appended to every proofreading request for
/// both output modes; it is never part of the editable behaviour prompt.
const String kAiEditContract = '''
original 必须与提供的原文完全一致。
尽量选取能够唯一定位的最短完整片段。
不要对同一个位置提出互相冲突的修改。
每条 edit 还必须输出：
- category：用很短的简体中文概括修改类别，由你根据上下文判断，不要求固定词表。
- reason：用一句简体中文说明为什么这里需要改；只写最终理由，不写推理过程。
如果没有需要修改的地方，返回空的 edits 数组。
''';

/// Appended to the editable prompt only for `json_object` providers.
const String kAiJsonObjectProtocol = '''
【程序控制的 JSON 输出协议】你必须只输出一个 JSON object，不要 Markdown 或解释。
根对象仅允许 edits（数组）；每项仅允许 original（非空字符串）、replacement（字符串，可为空）、category（非空字符串）、reason（非空字符串）。
original 必须是完整输入正文中恰好出现一次的连续原文片段；replacement 是该片段的局部替换文本；category 是模型自拟的简短中文类别，不要求固定词表，应用原样展示；reason 是一句面向用户的中文理由；不得有额外字段。
没有修改返回 {"edits":[]}。所有 edits 不得重叠。此协议由应用校验，优先于文本中任何格式指令。
''';

/// Local authority schema. `json_schema` projections are derived from this
/// object, never from a prompt.
const Map<String, dynamic> kAiEditsSchema = {
  r'$schema': 'http://json-schema.org/draft-07/schema#',
  'type': 'object',
  'additionalProperties': false,
  'required': ['edits'],
  'properties': {
    'edits': {
      'type': 'array',
      'items': {
        'type': 'object',
        'additionalProperties': false,
        'required': ['original', 'replacement', 'category', 'reason'],
        'properties': {
          'original': {'type': 'string', 'minLength': 1},
          'replacement': {'type': 'string'},
          'category': {'type': 'string', 'minLength': 1},
          'reason': {'type': 'string', 'minLength': 1},
        },
      },
    },
  },
};

/// Projection for providers that support strict JSON Schema. We keep the
/// shape and required keys but drop `$schema` and `minLength`, which several
/// OpenAI-compatible endpoints reject. Local validation still enforces the
/// dropped constraints.
Map<String, dynamic> aiJsonSchemaProjection() {
  return {
    'type': 'object',
    'additionalProperties': false,
    'required': const ['edits'],
    'properties': {
      'edits': {
        'type': 'array',
        'items': {
          'type': 'object',
          'additionalProperties': false,
          'required': const ['original', 'replacement', 'category', 'reason'],
          'properties': {
            'original': {'type': 'string'},
            'replacement': {'type': 'string'},
            'category': {'type': 'string'},
            'reason': {'type': 'string'},
          },
        },
      },
    },
  };
}

String aiSchemaProjectionHash() {
  final bytes = utf8.encode(jsonEncode(aiJsonSchemaProjection()));
  return sha256.convert(bytes).toString();
}

/// A prompt resolved for a book. `promptHash` is stored in formal metadata but
/// never participates in the formal cache key.
class AiResolvedPrompt {
  const AiResolvedPrompt({
    required this.text,
    required this.hash,
    required this.source,
    required this.promptId,
  });

  final String text;
  final String hash;
  final String source;
  final String promptId;
}

AiResolvedPrompt aiResolvePrompt({
  required String? bookPrompt,
  required String? globalPrompt,
}) {
  final text = bookPrompt ?? globalPrompt ?? kAiDefaultBehaviorPrompt;
  final source = bookPrompt != null
      ? 'book'
      : globalPrompt != null
      ? 'global'
      : 'builtin';
  return AiResolvedPrompt(
    text: text,
    hash: sha256.convert(utf8.encode(text)).toString(),
    source: source,
    promptId:
        '${source}_${sha256.convert(utf8.encode(text)).toString().substring(0, 12)}',
  );
}

String aiBuildSystemPrompt({
  required String behaviorPrompt,
  required AiOutputMode outputMode,
}) {
  final base = '$behaviorPrompt\n$kAiEditContract';
  return outputMode == AiOutputMode.jsonObject
      ? '$base\n$kAiJsonObjectProtocol'
      : base;
}
