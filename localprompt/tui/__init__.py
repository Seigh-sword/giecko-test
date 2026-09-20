import curses
import time
from typing import Any, Dict, List, Optional

from localprompt.utils import console


class LocalPromptTUI:
    """Terminal User Interface using curses."""

    def __init__(self, stdscr, agent_manager=None, model_runner=None):
        self.stdscr = stdscr
        self.agent_manager = agent_manager
        self.model_runner = model_runner
        self.current_input = ""
        self.messages: List[Dict[str, str]] = []
        self.history: List[str] = []
        self.running = True
        self.scroll_offset = 0
        curses.curs_set(0)
        self.stdscr.keypad(True)
        curses.init_pair(1, curses.COLOR_CYAN, curses.COLOR_BLACK)
        curses.init_pair(2, curses.COLOR_GREEN, curses.COLOR_BLACK)
        curses.init_pair(3, curses.COLOR_YELLOW, curses.COLOR_BLACK)
        curses.init_pair(4, curses.COLOR_RED, curses.COLOR_BLACK)
        curses.init_pair(5, curses.COLOR_WHITE, curses.COLOR_BLUE)
        curses.init_pair(6, curses.COLOR_MAGENTA, curses.COLOR_BLACK)

    def run(self):
        while self.running:
            self._draw()
            key = self.stdscr.getch()
            self._handle_key(key)

    def _draw(self):
        self.stdscr.erase()
        h, w = self.stdscr.getmaxyx()

        # Title bar
        title = "[LocalPrompt]"
        self.stdscr.attron(curses.color_pair(1) | curses.A_BOLD)
        self.stdscr.addstr(0, 0, title.ljust(w - 1)[:w - 1])
        self.stdscr.attroff(curses.color_pair(1) | curses.A_BOLD)

        # Memory bar
        mem_info = "Hive: 0 entries"
        if self.agent_manager:
            mem_info = f"Hive: {len(self.agent_manager.hive_mem.keys())} entries | Agents: {len(self.agent_manager.agents)}"
        self.stdscr.attron(curses.color_pair(3))
        self.stdscr.addstr(1, 0, mem_info.ljust(w - 1)[:w - 1])
        self.stdscr.attroff(curses.color_pair(3))

        # Messages area
        msg_start = 3
        max_msg_lines = h - msg_start - 3
        visible = self.messages[-max_msg_lines:] if len(self.messages) > max_msg_lines else self.messages

        for i, msg in enumerate(visible):
            line = msg_start + i
            if line >= h - 3:
                break
            role = msg.get("role", "user")
            content = msg.get("content", "")[:w - 2]
            if role == "user":
                prefix = "> "
                attr = curses.color_pair(2)
            elif role == "assistant":
                prefix = "A: "
                attr = curses.color_pair(6)
            else:
                prefix = "* "
                attr = curses.color_pair(3)
            self.stdscr.attron(attr)
            try:
                self.stdscr.addstr(line, 0, prefix + content)
            except curses.error:
                pass
            self.stdscr.attroff(attr)

        # Input area
        input_y = h - 2
        input_prompt = ">>> "
        self.stdscr.attron(curses.color_pair(5) | curses.A_BOLD)
        try:
            self.stdscr.addstr(input_y, 0, input_prompt)
        except curses.error:
            pass
        self.stdscr.attroff(curses.color_pair(5) | curses.A_BOLD)

        display_input = self.current_input[:w - len(input_prompt) - 1]
        try:
            self.stdscr.addstr(input_y, len(input_prompt), display_input)
        except curses.error:
            pass

        # Cursor
        cursor_x = len(input_prompt) + len(display_input)
        try:
            curses.curs_set(1)
            self.stdscr.move(input_y, cursor_x)
        except curses.error:
            pass

        self.stdscr.refresh()

    def _handle_key(self, key: int):
        h, w = self.stdscr.getmaxyx()
        input_y = h - 2
        input_prompt = ">>> "

        if key == curses.KEY_ENTER or key == 10:
            if self.current_input.strip():
                self.messages.append({"role": "user", "content": self.current_input})
                self._process_input(self.current_input)
                self.current_input = ""
                self.scroll_offset = 0
        elif key == curses.KEY_BACKSPACE or key == 127 or key == 8:
            self.current_input = self.current_input[:-1]
        elif key == curses.KEY_LEFT:
            pass
        elif key == curses.KEY_RIGHT:
            pass
        elif key == curses.KEY_UP:
            if self.history:
                self.current_input = self.history[-1]
        elif key == curses.KEY_DOWN:
            self.current_input = ""
        elif key == 27:
            self.running = False
        elif 32 <= key <= 126:
            self.current_input += chr(key)

        if len(self.current_input) > w - len(input_prompt) - 2:
            self.current_input = self.current_input[:w - len(input_prompt) - 2]

    def _process_input(self, inp: str):
        self.history.append(inp)
        inp_lower = inp.lower().strip()

        if inp_lower == "/quit" or inp_lower == "/exit":
            self.running = False
            return
        elif inp_lower == "/agents":
            self._show_agents()
            return
        elif inp_lower == "/memory":
            self._show_memory()
            return
        elif inp_lower.startswith("/role"):
            self._rotate_roles()
            return
        elif inp_lower == "/swarm":
            self._start_swarm()
            return
        elif inp_lower.startswith("/reason"):
            self._reason(inp[7:].strip())
            return
        elif inp_lower.startswith("/search"):
            self._web_search(inp[8:].strip())
            return

        if self.model_runner:
            self._chat_with_model(inp)
        elif self.agent_manager:
            self._chat_with_agents(inp)
        else:
            self.messages.append({"role": "system", "content": "No model or agent available. Use /agents to create one."})

    def _chat_with_model(self, inp: str):
        self.messages.append({"role": "system", "content": "Thinking..."})
        try:
            result = self.model_runner.generate_full(inp, max_tokens=256)
            self.messages.append({"role": "assistant", "content": result.text})
        except Exception as e:
            self.messages.append({"role": "system", "content": f"Error: {e}"})

    def _chat_with_agents(self, inp: str):
        self.messages.append({"role": "system", "content": "Broadcasting to agents..."})
        if self.agent_manager:
            responses = self.agent_manager.team_chat(inp)
            for name, response in responses.items():
                self.messages.append({"role": "assistant", "content": f"[{name}]: {response}"})

    def _show_agents(self):
        self.messages.append({"role": "system", "content": "=== Agents ==="})
        if self.agent_manager:
            for agent in self.agent_manager.list_agents():
                self.messages.append({"role": "system", "content": f"{agent.name}: {agent.role.value} | Tasks: {agent.total_tasks}"})

    def _show_memory(self):
        self.messages.append({"role": "system", "content": "=== Hive Memory ==="})
        if self.agent_manager:
            for key in self.agent_manager.hive_mem.keys()[:10]:
                val = str(self.agent_manager.hive_mem.retrieve(key))[:80]
                self.messages.append({"role": "system", "content": f"{key}: {val}"})

    def _rotate_roles(self):
        if self.agent_manager:
            self.agent_manager.rotate_roles()
            self.messages.append({"role": "system", "content": "Roles rotated!"})

    def _start_swarm(self):
        self.messages.append({"role": "system", "content": "=== Swarm Mode Activated ==="})

    def _reason(self, text: str):
        from localprompt.tools.reasoning import Reasoner
        reasoner = Reasoner()
        result = reasoner.reason(text)
        self.messages.append({"role": "assistant", "content": f"Reasoning:\n{result}"})

    def _web_search(self, query: str):
        from localprompt.tools.web_search import web_search
        results = web_search(query)
        for r in results[:5]:
            self.messages.append({"role": "system", "content": f"{r.get('title', '')}: {r.get('url', '')}"})
