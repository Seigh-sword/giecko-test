#!/usr/bin/env python3
import ollama
import sys

MODEL = "llama2-uncensored:latest"

def chat(message: str) -> str:
    response = ollama.chat(model=MODEL, messages=[{"role": "user", "content": message}])
    return response["message"]["content"]

def main():
    if len(sys.argv) < 2:
        print("Usage: python agent.py \"your question here\"")
        sys.exit(1)
    
    message = " ".join(sys.argv[1:])
    response = chat(message)
    print(response)

if __name__ == "__main__":
    main()