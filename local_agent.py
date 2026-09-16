import os
import sys
from langchain_ollama import ChatOllama
from langchain_core.messages import HumanMessage, SystemMessage

def run_local_agent(prompt_task: str):
    print(f"🚀 Initializing local agent with Qwen 2.5...")
    
    # Initialize the connection to your local Ollama server
    llm = ChatOllama(
        model="qwen2.5",
        temperature=0.3,
        base_url="http://localhost:11434"
    )
    
    messages = [
        SystemMessage(content=(
            "You are an expert Linux automation AI agent. "
            "Provide clean, production-ready code blocks and straightforward explanations."
        )),
        HumanMessage(content=prompt_task)
    ]
    
    print(f"🧠 Processing task: '{prompt_task}'\n")
    
    try:
        # Stream the output directly from Qwen 2.5 token by token
        for chunk in llm.stream(messages):
            sys.stdout.write(chunk.content)
            sys.stdout.flush()
        print("\n\n✅ Task complete.")
        
    except Exception as e:
        print(f"\n❌ Error connecting to Ollama: {e}")
        print("Make sure 'ollama run qwen2.5' is active in your terminal.")

if __name__ == "__main__":
    task = "Create a simple Python utility that monitors system CPU and RAM usage, saving logs to system_health.txt"
    run_local_agent(task)
