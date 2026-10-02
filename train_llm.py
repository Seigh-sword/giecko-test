from datasets import load_dataset
import torch
from transformers import (
    AutoModelForCausalLM,
    AutoTokenizer,
    BitsAndBytesConfig,
    TrainingArguments,
)
from peft import LoraConfig, get_peft_model, prepare_model_for_kbit_training
from trl import SFTConfig, SFTTrainer

# 1. Configuration & Hyperparameters
MODEL_ID = (  # Swap for any open base model like Mistral-7B, Llama-3-8B, etc.
    "facebook/opt-350m"
)
DATASET_NAME = "timdettmers/openassistant-guanaco"  # High-quality instruction dataset

print(f"Initializing QLoRA fine-tuning pipeline for {MODEL_ID}... 🚀")

# 2. Load Tokenizer
tokenizer = AutoTokenizer.from_pretrained(MODEL_ID, trust_remote_code=True)
tokenizer.pad_token = tokenizer.eos_token
tokenizer.padding_side = "right"

# 3. Configure 4-bit Quantization (BitsAndBytes)
bnb_config = BitsAndBytesConfig(
    load_in_4bit=True,
    bnb_4bit_quant_type="nf4",
    bnb_4bit_compute_dtype=torch.bfloat16
    if torch.cuda.is_available()
    else torch.float16,
    bnb_4bit_use_double_quant=True,
)

# 4. Load Base Model in Quantized Format
model = AutoModelForCausalLM.from_pretrained(
    MODEL_ID, quantization_config=bnb_config, device_map="auto"
)

# Prepare model for k-bit training
model = prepare_model_for_kbit_training(model)

# 5. Configure LoRA (Low-Rank Adaptation)
peft_config = LoraConfig(
    r=16,  # Rank
    lora_alpha=32,  # Scaling parameter
    target_modules=["q_proj", "v_proj"],  # Target attention layers
    lora_dropout=0.05,
    bias="none",
    task_type="CAUSAL_LM",
)

model = get_peft_model(model, peft_config)
model.print_trainable_parameters()

# 6. Load Dataset (Streaming a subset for quick execution)
dataset = load_dataset(DATASET_NAME, split="train[:500]")

# 7. Training Arguments
training_args = TrainingArguments(
    output_dir="./giecko_finetuned_model",
    per_device_train_batch_size=2,
    gradient_accumulation_steps=4,
    learning_rate=2e-4,
    logging_steps=10,
    num_train_epochs=1,
    max_steps=50,  # Limit steps for a fast test run
    fp16=not torch.cuda.is_available(),
    bf16=torch.cuda.is_available(),
    optim="paged_adamw_8bit",
    save_strategy="steps",
    save_steps=25,
)

# 8. Initialize Trainer (SFTTrainer)
sft_config = SFTConfig(
    output_dir="./giecko_finetuned_model",
    per_device_train_batch_size=2,
    gradient_accumulation_steps=4,
    learning_rate=2e-4,
    logging_steps=10,
    num_train_epochs=1,
    max_steps=50,
    fp16=not torch.cuda.is_available(),
    bf16=torch.cuda.is_available(),
    optim="paged_adamw_8bit",
    save_strategy="steps",
    save_steps=25,
    dataset_text_field="text",
    max_seq_length=512,
)

trainer = SFTTrainer(
    model=model,
    train_dataset=dataset,
    peft_config=peft_config,
    args=sft_config,
    tokenizer=tokenizer,
)

# 9. Start Training
print("Starting model fine-training... 🧠🔥")
trainer.train()

# 10. Save Fine-Tuned Adapter
trainer.model.save_pretrained("./giecko_finetuned_adapter")
tokenizer.save_pretrained("./giecko_finetuned_adapter")
print(
    "Fine-tuning complete! Adapter saved locally to ./giecko_finetuned_adapter"
    " 💾✨"
)