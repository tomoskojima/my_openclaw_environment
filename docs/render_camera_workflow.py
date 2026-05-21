"""Render a sequence diagram of the camera-capture workflow as a PNG image."""

import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, FancyArrowPatch


ACTORS = [
    ("User", "Discord\nclient"),
    ("Discord", "Discord\nservers"),
    ("DP", "@openclaw/\ndiscord"),
    ("GW", "OpenClaw\nGateway"),
    ("CX", "Codex\nharness"),
    ("LLM", "OpenAI\ngpt-5.5"),
    ("CP", "openclaw-\ncamera plugin"),
    ("FF", "ffmpeg\nsubprocess"),
    ("V4L", "/dev/video0\n(C920)"),
    ("FS", "./work/\n(bind mount)"),
    ("MT", "message tool\n(group:messaging)"),
]

CLOUD_ACTORS = {"User", "Discord", "LLM"}
HOST_ACTORS = {"V4L", "FS"}

MESSAGES = [
    ("User", "Discord", '"Please take picture of camera and post it in this"', "in"),
    ("Discord", "DP", "MESSAGE_CREATE (WebSocket)", "in"),
    ("DP", "GW", "forward (guild + channel allow-listed)", "in"),
    ("GW", "CX", "route -> agent \"main\"", "in"),
    ("CX", "LLM", "chat.completions { messages, tools[] }", "in"),
    ("LLM", "CX", "tool_call: capture_camera_frame({})", "ret"),
    ("CX", "CP", "execute(params, config, ctx)", "in"),
    ("CP", "FF", "spawn ffmpeg -f v4l2 -i /dev/video0 ...", "in"),
    ("FF", "V4L", "open + read 1 YUYV frame", "in"),
    ("V4L", "FF", "raw frame", "ret"),
    ("FF", "FS", "write camera_<ts>.jpg (~65 KB)", "in"),
    ("FF", "CP", "exit 0", "ret"),
    ("CP", "CX", "{ path, relative, bytes, device, resolution }", "ret"),
    ("CX", "LLM", "chat.completions + tool_result", "in"),
    ("LLM", "CX", "tool_call: message.sendAttachment({ files:[{path}] })", "ret"),
    ("CX", "MT", "outbound media payload", "in"),
    ("MT", "DP", "attach + reply", "in"),
    ("DP", "Discord", "POST /channels/<C>/messages (multipart)", "in"),
    ("Discord", "User", "message + inline JPEG", "ret"),
]


def render(out_path: str) -> None:
    n_actors = len(ACTORS)
    n_msgs = len(MESSAGES)

    actor_spacing = 2.6
    box_half_w = 0.85
    x_positions = {actor[0]: i * actor_spacing for i, actor in enumerate(ACTORS)}

    fig_w = max(20, actor_spacing * n_actors + 4)
    fig_h = max(14, 0.75 * n_msgs + 4)
    fig, ax = plt.subplots(figsize=(fig_w, fig_h), dpi=150)

    actor_y = n_msgs * 0.9 + 2.2
    bottom_y = 0.4

    cloud_color = "#E3F2FD"
    cloud_edge = "#1565C0"
    host_color = "#FFF8E1"
    host_edge = "#EF6C00"
    container_color = "#E8F5E9"
    container_edge = "#2E7D32"

    for code, label in ACTORS:
        x = x_positions[code]
        if code in CLOUD_ACTORS:
            fc, ec = cloud_color, cloud_edge
        elif code in HOST_ACTORS:
            fc, ec = host_color, host_edge
        else:
            fc, ec = container_color, container_edge
        box = FancyBboxPatch(
            (x - box_half_w, actor_y - 0.55),
            box_half_w * 2, 1.1,
            boxstyle="round,pad=0.02,rounding_size=0.08",
            linewidth=1.6, edgecolor=ec, facecolor=fc,
        )
        ax.add_patch(box)
        ax.text(x, actor_y, label, ha="center", va="center", fontsize=10, weight="bold")
        ax.plot([x, x], [actor_y - 0.6, bottom_y], color="#888", linestyle=(0, (3, 3)), linewidth=0.8, zorder=1)

    msg_row_height = 0.9
    for i, (src, dst, label, kind) in enumerate(MESSAGES):
        y = actor_y - 1.2 - i * msg_row_height
        x0 = x_positions[src]
        x1 = x_positions[dst]
        color = "#1B5E20" if kind == "in" else "#0D47A1"
        arrow = FancyArrowPatch(
            (x0, y), (x1, y),
            arrowstyle="-|>", mutation_scale=16,
            linewidth=1.6, color=color, zorder=3,
        )
        ax.add_patch(arrow)

        mid_x = (x0 + x1) / 2.0
        label_text = f"{i+1}. {label}"
        ax.text(
            mid_x, y + 0.16, label_text,
            ha="center", va="bottom", fontsize=9, color="#222",
            bbox=dict(boxstyle="round,pad=0.25", facecolor="white", edgecolor="#CCC", linewidth=0.7),
            zorder=4,
        )

    legend_y = bottom_y - 0.6
    legend_entries = [
        ("Cloud (Discord, OpenAI)", cloud_color, cloud_edge),
        ("Container (openclaw-env)", container_color, container_edge),
        ("Host kernel / filesystem", host_color, host_edge),
    ]
    legend_x = 0.0
    for label, fc, ec in legend_entries:
        sw_box = FancyBboxPatch(
            (legend_x, legend_y - 0.25),
            0.7, 0.5,
            boxstyle="round,pad=0.02,rounding_size=0.08",
            linewidth=1.2, edgecolor=ec, facecolor=fc,
        )
        ax.add_patch(sw_box)
        ax.text(legend_x + 0.85, legend_y, label, ha="left", va="center", fontsize=10)
        legend_x += 6.0

    arrow_legend_x = legend_x
    for label, color in [("forward (in)", "#1B5E20"), ("return / tool_call result", "#0D47A1")]:
        arrow = FancyArrowPatch(
            (arrow_legend_x, legend_y), (arrow_legend_x + 1.0, legend_y),
            arrowstyle="-|>", mutation_scale=14, linewidth=1.6, color=color,
        )
        ax.add_patch(arrow)
        ax.text(arrow_legend_x + 1.15, legend_y, label, ha="left", va="center", fontsize=10)
        arrow_legend_x += 5.5

    ax.set_title(
        'Camera-capture workflow: Discord user says "Please take picture of camera and post it in this"',
        fontsize=14, weight="bold", pad=20,
    )

    x_max = max(x_positions.values())
    ax.set_xlim(-1.5, x_max + 1.5)
    ax.set_ylim(legend_y - 0.8, actor_y + 1.0)
    ax.set_xticks([])
    ax.set_yticks([])
    for spine in ax.spines.values():
        spine.set_visible(False)
    ax.set_aspect("auto")

    plt.tight_layout()
    fig.savefig(out_path, dpi=150, bbox_inches="tight", facecolor="white")
    print(f"wrote {out_path}")


if __name__ == "__main__":
    render("/home/jovyan/work/docs/camera-workflow.png")
