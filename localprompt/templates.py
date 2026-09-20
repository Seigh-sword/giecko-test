CHAT_TEMPLATES = {
    "llama2": """[INST] <<SYS>>
{system}
<</SYS>>

{history}{user}[/INST]""",
    "llama2-chat": """[INST] <<SYS>>
{system}
<</SYS>>

{history}{user}[/INST]""",
    "qwen2": """<|im_start|>system
{system}<|im_end|>
<|im_start|>user
{history}{user}<|im_end|>
<|im_start|>assistant
""",
    "qwen2-chat": """<|im_start|>system
{system}<|im_end|>
<|im_start|>user
{history}{user}<|im_end|>
<|im_start|>assistant
""",
    "chatglm": """<|system|>
{system}<|end|>
<|user|>
{history}{user}<|end|>
<|assistant|>
""",
    "default": """[INST]
{history}{user}[/INST]""",
}


def get_template(model_name="llama2"):
    name = model_name.lower()
    for key in CHAT_TEMPLATES:
        if key in name:
            return CHAT_TEMPLATES[key]
    return CHAT_TEMPLATES["default"]


def format_chat(template, system_message, conversation, user_message):
    history_parts = []
    for i, (u, a) in enumerate(conversation):
        history_parts.append(f"{u}[/INST] {a}")
        if i < len(conversation) - 1:
            history_parts.append("[INST] ")
    history = "\n".join(history_parts)

    return template.format(
        system=system_message,
        history=history,
        user=user_message,
    )


def detect_template_from_prompt(prompt):
    if "<|im_start|>" in prompt or "<|im_end|>" in prompt:
        return "qwen2"
    if "[INST]" in prompt and "<</SYS>>>" in prompt:
        return "llama2"
    if "<|system|>" in prompt and "<|end|>" in prompt:
        return "chatglm"
    return "default"
