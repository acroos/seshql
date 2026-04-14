import { Controller } from "@hotwired/stimulus"

// Chart.js is loaded via CDN in the layout - available as window.Chart
export default class extends Controller {
  static targets = ["canvas"]
  static values = {
    type: { type: String, default: "bar" },
    data: String,
    config: { type: String, default: "{}" }
  }

  connect() {
    if (typeof Chart === "undefined") {
      // Wait for Chart.js to load
      const interval = setInterval(() => {
        if (typeof Chart !== "undefined") {
          clearInterval(interval)
          this.renderChart()
        }
      }, 50)
    } else {
      this.renderChart()
    }
  }

  disconnect() {
    if (this.chart) {
      this.chart.destroy()
      this.chart = null
    }
  }

  renderChart() {
    const data = JSON.parse(this.dataValue)
    if (!data || !data.labels || !data.datasets) return

    const config = JSON.parse(this.configValue)
    const ctx = this.canvasTarget.getContext("2d")
    const chartType = this.typeValue === "stacked_bar" ? "bar" : this.typeValue
    const stacked = this.typeValue === "stacked_bar"

    // Determine which datasets go on secondary y-axis
    const secondaryLabels = config.secondary_y_datasets || []
    const hasSecondaryAxis = secondaryLabels.length > 0

    const colors = [
      "rgba(99, 102, 241, 0.8)",   // indigo (accent)
      "rgba(168, 85, 247, 0.8)",   // purple
      "rgba(59, 130, 246, 0.8)",   // blue
      "rgba(16, 185, 129, 0.8)",   // emerald
      "rgba(245, 158, 11, 0.8)",   // amber
      "rgba(239, 68, 68, 0.8)",    // red
      "rgba(236, 72, 153, 0.8)",   // pink
      "rgba(14, 165, 233, 0.8)",   // sky
      "rgba(34, 197, 94, 0.8)",    // green
      "rgba(251, 146, 60, 0.8)",   // orange
    ]

    const borderColors = colors.map(c => c.replace("0.8)", "1)"))

    const datasets = data.datasets.map((ds, i) => {
      const isSecondary = secondaryLabels.includes(ds.label)
      return {
        label: ds.label,
        data: ds.data,
        backgroundColor: colors[i % colors.length],
        borderColor: borderColors[i % borderColors.length],
        borderWidth: chartType === "line" ? 2 : 1,
        fill: false,
        tension: 0.3,
        pointRadius: chartType === "line" ? 3 : undefined,
        pointHoverRadius: chartType === "line" ? 5 : undefined,
        ...(hasSecondaryAxis ? { yAxisID: isSecondary ? "y1" : "y" } : {})
      }
    })

    const formatTick = function(value) {
      if (value >= 1_000_000) return (value / 1_000_000).toFixed(1) + "M"
      if (value >= 1_000) return (value / 1_000).toFixed(0) + "K"
      return value
    }

    const scales = {
      x: {
        stacked: stacked,
        ticks: {
          color: "#6b7280",
          font: { size: 10 },
          maxRotation: 45,
          autoSkip: true,
          maxTicksLimit: 30
        },
        grid: { color: "rgba(42, 46, 61, 0.5)" },
        border: { color: "#2a2e3d" }
      },
      y: {
        stacked: stacked,
        beginAtZero: true,
        position: "left",
        title: hasSecondaryAxis ? {
          display: true,
          text: config.y_axis_label || "",
          color: "#6b7280",
          font: { size: 11 }
        } : undefined,
        ticks: {
          color: "#6b7280",
          font: { size: 10 },
          callback: formatTick
        },
        grid: { color: "rgba(42, 46, 61, 0.5)" },
        border: { color: "#2a2e3d" }
      }
    }

    if (hasSecondaryAxis) {
      scales.y1 = {
        beginAtZero: true,
        position: "right",
        title: {
          display: true,
          text: config.y1_axis_label || "",
          color: "#6b7280",
          font: { size: 11 }
        },
        ticks: {
          color: "#6b7280",
          font: { size: 10 },
          callback: formatTick
        },
        grid: { drawOnChartArea: false },
        border: { color: "#2a2e3d" }
      }
    }

    this.chart = new Chart(ctx, {
      type: chartType,
      data: {
        labels: data.labels,
        datasets: datasets
      },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        interaction: {
          intersect: false,
          mode: "index"
        },
        plugins: {
          legend: {
            display: data.datasets.length > 1,
            position: "top",
            labels: {
              color: "#9ca3af",
              font: { size: 11 },
              boxWidth: 12,
              padding: 16
            }
          },
          tooltip: {
            backgroundColor: "#1a1d27",
            titleColor: "#e5e7eb",
            bodyColor: "#9ca3af",
            borderColor: "#2a2e3d",
            borderWidth: 1,
            padding: 10,
            callbacks: {
              label: function(ctx) {
                let value = ctx.parsed.y
                if (value >= 1_000_000) {
                  value = (value / 1_000_000).toFixed(1) + "M"
                } else if (value >= 1_000) {
                  value = (value / 1_000).toFixed(1) + "K"
                } else {
                  value = value.toLocaleString()
                }
                return `${ctx.dataset.label}: ${value}`
              }
            }
          }
        },
        scales: scales
      }
    })
  }
}
