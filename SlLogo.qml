import QtQuick
import QtQuick.Shapes
import qs.Commons

// The Storstockholms Lokaltrafik mark, drawn as vector paths so it can take the
// Omarchy theme's foreground colour instead of SL's brand blue, and stay crisp
// at any size. Geometry traced from the public-domain logo on Wikimedia Commons
// (Storstockholms_Lokaltrafik_logo.svg, kept alongside as assets/sl-logo.svg),
// with that file's nested transforms flattened into the 210x171 space these
// paths are written in.
//
// The mark is a trademark of its owner and appears here only to identify whose
// departure data the widget shows.
Item {
  id: root

  // Height drives the mark; width follows the logo's own 210:171 ratio.
  property real logoSize: Style.font.heading
  property color color: Color.foreground

  readonly property real aspect: 210 / 171

  implicitWidth: Math.round(logoSize * aspect)
  implicitHeight: Math.round(logoSize)

  Shape {
    width: 210
    height: 171
    antialiasing: true
    layer.enabled: true
    layer.samples: 4
    // The paths are authored at the logo's native size; scaling the Shape from
    // its top-left corner fits them to whatever box the caller asks for.
    transform: Scale {
      xScale: root.width / 210
      yScale: root.height / 171
    }

      // Ring
      ShapePath {
        fillColor: root.color
        strokeWidth: 0
        fillRule: ShapePath.WindingFill
        PathSvg {
          path: "M 105.1058,131.7592 C 122.6808,131.7592 139.2049,124.9006 151.6330,112.4619"
            + " " + "C 164.0646,100.0196 170.9081,83.4801 170.9081,65.8814"
            + " " + "C 170.9081,48.2862 164.0646,31.7360 151.6330,19.2972"
            + " " + "C 139.2049,6.8585 122.6808,0.0000 105.1058,0.0000"
            + " " + "C 68.8224,0.0000 39.2999,29.5527 39.2999,65.8814"
            + " " + "C 39.2999,83.4801 46.1470,100.0196 58.5750,112.4619"
            + " " + "C 71.0067,124.9006 87.5308,131.7592 105.1058,131.7592 M 49.6441,65.8814"
            + " " + "C 49.6441,51.0440 55.4080,37.1043 65.8884,26.6190"
            + " " + "C 76.3617,16.1337 90.2890,10.3596 105.1058,10.3596"
            + " " + "C 119.9190,10.3596 133.8464,16.1337 144.3196,26.6190"
            + " " + "C 154.7929,37.1043 160.5640,51.0440 160.5640,65.8814"
            + " " + "C 160.5640,96.4934 135.6828,121.3996 105.1058,121.3996"
            + " " + "C 90.2890,121.3996 76.3617,115.6255 65.8884,105.1402"
            + " " + "C 55.4080,94.6549 49.6441,80.7080 49.6441,65.8814"
        }
      }

      // S
      ShapePath {
        fillColor: root.color
        strokeWidth: 0
        fillRule: ShapePath.WindingFill
        PathSvg {
          path: "M 74.8732,74.9698 C 74.9557,78.1765 76.8459,84.8159 85.4935,84.8159"
            + " " + "C 91.4941,84.8159 95.7839,81.4765 95.7839,77.5265"
            + " " + "C 95.7839,73.5155 93.3808,70.0037 86.4870,68.6679 L 79.2275,67.2423"
            + " " + "C 69.9629,65.1273 64.2995,60.1971 64.2995,51.2953"
            + " " + "C 64.2995,42.2823 70.7664,33.5242 85.6693,33.5242"
            + " " + "C 102.4660,33.5242 106.0097,46.2394 106.0097,51.2522 L 94.5178,51.2522"
            + " " + "C 94.5178,51.2522 94.9266,42.7455 84.9842,42.7455"
            + " " + "C 79.5180,42.7455 75.8308,45.1586 75.8308,50.3689"
            + " " + "C 75.8308,54.9544 80.0883,56.6134 82.5416,57.1736 L 93.2947,59.4789"
            + " " + "C 101.8096,61.5257 107.6667,66.0609 107.6667,76.0040"
            + " " + "C 107.6667,90.3494 94.9446,94.4215 85.5832,94.4215"
            + " " + "C 69.0663,94.4215 63.4387,83.3365 63.4387,74.9698 L 74.8732,74.9698"
        }
      }

      // L
      ShapePath {
        fillColor: root.color
        strokeWidth: 0
        fillRule: ShapePath.WindingFill
        PathSvg {
          path: "M 126.7805,83.0528 L 148.8210,83.0528 L 148.8210,93.2006 L 114.9263,93.2006"
            + " " + "L 114.9263,34.6050 L 126.7805,34.6050 L 126.7805,83.0528"
        }
      }

      // Outer arc
      ShapePath {
        fillColor: root.color
        strokeWidth: 0
        fillRule: ShapePath.WindingFill
        PathSvg {
          path: "M 199.3402,58.1144 C 199.5482,60.6854 199.6523,63.2708 199.6523,65.8814"
            + " " + "C 199.6523,91.1969 189.8138,114.9935 171.9339,132.8867"
            + " " + "C 154.0540,150.7871 130.2847,160.6476 105.0018,160.6476"
            + " " + "C 79.7189,160.6476 55.9460,150.7871 38.0661,132.8867"
            + " " + "C 20.1862,114.9935 10.3406,91.1969 10.3406,65.8814"
            + " " + "C 10.3406,63.2708 10.4553,60.6854 10.6634,58.1144 L 0.2798,58.1144"
            + " " + "C 0.0933,60.6890 0.0000,63.2744 0.0000,65.8814"
            + " " + "C 0.0000,93.9583 10.9216,120.3618 30.7563,140.2084"
            + " " + "C 50.5874,160.0694 76.9535,171.0036 105.0018,171.0036"
            + " " + "C 133.0501,171.0036 159.4126,160.0694 179.2473,140.2084"
            + " " + "C 199.0820,120.3618 210.0000,93.9583 210.0000,65.8814"
            + " " + "C 210.0000,63.2744 209.9103,60.6890 209.7202,58.1144 L 199.3402,58.1144"
        }
      }

      // Inner arc
      ShapePath {
        fillColor: root.color
        strokeWidth: 0
        fillRule: ShapePath.WindingFill
        PathSvg {
          path: "M 179.6634,58.1144 C 179.9216,60.6782 180.0579,63.2672 180.0579,65.8814"
            + " " + "C 180.0579,85.9542 172.2496,104.8242 158.0712,119.0188"
            + " " + "C 143.8964,133.2099 125.0481,141.0307 105.0018,141.0307"
            + " " + "C 84.9519,141.0307 66.1036,133.2099 51.9252,119.0188"
            + " " + "C 37.7504,104.8242 29.9349,85.9542 29.9349,65.8814"
            + " " + "C 29.9349,63.2672 30.0820,60.6782 30.3331,58.1144 L 19.9494,58.1144"
            + " " + "C 19.7163,60.6854 19.5979,63.2708 19.5979,65.8814"
            + " " + "C 19.5979,88.7228 28.4787,110.1925 44.6119,126.3442"
            + " " + "C 60.7378,142.4886 82.1865,151.3796 105.0018,151.3796"
            + " " + "C 127.8063,151.3796 149.2550,142.4886 165.3881,126.3442"
            + " " + "C 181.5177,110.1925 190.3985,88.7228 190.3985,65.8814"
            + " " + "C 190.3985,63.2708 190.2765,60.6854 190.0470,58.1144 L 179.6634,58.1144"
        }
      }
  }
}
