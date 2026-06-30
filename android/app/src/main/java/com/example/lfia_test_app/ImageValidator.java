package com.example.lfia_test_app;

import android.util.Log;
import org.opencv.android.OpenCVLoader;

import org.opencv.core.*;
import org.opencv.imgcodecs.Imgcodecs;
import org.opencv.imgproc.Imgproc;

import java.util.*;

// new for API
import java.util.Locale;
public class ImageValidator {

    private static final String TAG = "ImageValidator";

    // OpenCV initialization
    private static void ensureOpenCV() {
        if (!OpenCVLoader.initDebug()) {
            Log.e("OpenCV", "There seems to be a problem while loading OpenCV");
            throw new IllegalStateException("OpenCV not initialized");
        }
    }

    // result definer
    public static final class SingleResult {
        public final boolean usable;
        public final String contrastExposure; // acceptable or unacceptable
        public final String blurriness;       // clear  or blurry
       // public final String orientation;      // portrait / landscape / uncertain
        //public final String details;          // reasons for fail --> might change

        public SingleResult(boolean usable, String contrastExposure, String blurriness, String details) {
            this.usable = usable;
            this.contrastExposure = contrastExposure;
            this.blurriness = blurriness;
           // this.orientation = orientation;
          //  this.details = details;
        }

        @Override public String toString() {
            return "usable=" + usable +
                    ", contrastExposure=" + contrastExposure +
                    ", blurriness=" + blurriness;
                  // +  ", orientation=" + orientation;
        }
    }

    /**
     * Pass condition --> The picture will pass if:
     *   contrast/exposure == "Acceptable"
     *   && blurriness starts with "Clear"
     *   && orientation == "Portrait"
     */
    public static SingleResult evaluateSingleImage(String imagePath) {
        ensureOpenCV();

        String contrastResult = checkContrastExposure(imagePath);
        String blurResult = checkBlurriness(imagePath);
       // String orientationResult = checkOrientation(imagePath);

        boolean isAcceptableCE = "Acceptable".equalsIgnoreCase(contrastResult);
        boolean isClear        = blurResult != null && blurResult.toLowerCase().startsWith("clear");
       // boolean isPortrait     = "Portrait".equalsIgnoreCase(orientationResult);

       // boolean usable = isAcceptableCE && isClear && isPortrait;
        boolean usable = isAcceptableCE && isClear; // orientation check removed

        StringBuilder why = new StringBuilder();
        if (usable) {
            why.append("All checks passed.");
        } else {
            if (!isAcceptableCE) why.append("Exposure/Contrast unacceptable.\n");
            if (!isClear)        why.append("Image is blurry.\n");
           // if (!isPortrait)     why.append("Incorrect orientation: ").append(orientationResult).append(".\n");
        }

        //  return new SingleResult(usable, contrastResult, blurResult, orientationResult, why.toString().trim());
        return new SingleResult(usable, contrastResult, blurResult, why.toString().trim());
    }

    // ---------------- Logic for checks  --> don't change , sensitive----------------

    public static String checkContrastExposure(String imagePath) {
        Mat img = Imgcodecs.imread(imagePath, Imgcodecs.IMREAD_GRAYSCALE);
        if (img.empty()) {
            return "Unacceptable";
        }

        MatOfDouble mean = new MatOfDouble();
        MatOfDouble stddev = new MatOfDouble();
        Core.meanStdDev(img, mean, stddev);
        double stdDevValue = stddev.toArray()[0];

        Mat hist = new Mat();
        Imgproc.calcHist(Arrays.asList(img), new MatOfInt(0), new Mat(), hist, new MatOfInt(256), new MatOfFloat(0, 256));

        double totalPixels = (double) img.rows() * (double) img.cols();
        double extremePixels = (hist.get(0,0)[0] + hist.get(255,0)[0]) / totalPixels;

        double midRangeSum = 0.0;
        for (int i = 10; i <= 245; i++) {
            midRangeSum += hist.get(i,0)[0];
        }
        double midRangeRatio = midRangeSum / totalPixels;

        boolean lowContrast = stdDevValue < 20.0;
        boolean extreme = extremePixels > 0.15;
        boolean weakMid = midRangeRatio < 0.4;

        img.release();
        hist.release();

        if (lowContrast || extreme || weakMid) {
            return "Unacceptable";
        } else {
            return "Acceptable";
        }
    }

    // tuning for best results
    private static final boolean USE_PREBLUR = true;     // true
    private static final boolean USE_CENTER_ROI = false;
    private static final double  ROI_FRACTION  = 0.55;
    private static final int LAPL_KSIZE = 3;
    private static final double  BLURRINESS_THRESH = 90.0; // decision threshold --> good precision of blurriness and clarity


    public static String checkBlurriness(String imagePath) {
        final String TAG = "ImageValidator";

        // read  grayscale
        Mat gray = Imgcodecs.imread(imagePath, Imgcodecs.IMREAD_GRAYSCALE);
        if (gray.empty()) return "Blurry";
        Log.d(TAG, "src size=" + gray.cols() + "x" + gray.rows() +
                " channels=" + gray.channels() + " depth=" + gray.depth());

        if (USE_PREBLUR) {
            Imgproc.GaussianBlur(gray, gray, new Size(3,3), 0);
        }

        Mat work = gray;
        Rect roiRect = null;
        if (USE_CENTER_ROI) {
            int w = gray.cols(), h = gray.rows();
            int rw = (int)(w * ROI_FRACTION), rh = (int)(h * ROI_FRACTION);
            int rx = (w - rw) / 2, ry = (h - rh) / 2;
            roiRect = new Rect(rx, ry, rw, rh);
            work = new Mat(gray, roiRect);
        }

        // Signed Laplacian
        Mat lap = new Mat();
        Imgproc.Laplacian(work, lap, CvType.CV_64F, LAPL_KSIZE, 1, 0, Core.BORDER_DEFAULT);

        // Variance = std^2 of Laplacian
        MatOfDouble mean = new MatOfDouble();
        MatOfDouble std  = new MatOfDouble();
        Core.meanStdDev(lap, mean, std);
        double variance = std.get(0,0)[0];
        variance *= variance;

        // Cleanup
        if (work != gray) work.release();
        lap.release();
        gray.release();
        mean.release();
        std.release();

        return (variance < BLURRINESS_THRESH)
                ? String.format(java.util.Locale.US, "Blurry (Variance = %.2f)", variance)
                : String.format(java.util.Locale.US, "Clear (Variance = %.2f)", variance);
    }


    public static String checkOrientation(String imagePath) {
        Mat image = Imgcodecs.imread(imagePath);
        if (image.empty()) {
            return "Uncertain";
        }

        Mat gray = new Mat();
        Imgproc.cvtColor(image, gray, Imgproc.COLOR_BGR2GRAY);

        Mat thresh = new Mat();
        Imgproc.adaptiveThreshold(gray, thresh, 255, Imgproc.ADAPTIVE_THRESH_MEAN_C, Imgproc.THRESH_BINARY, 13, 5);

        int whitePixels = Core.countNonZero(thresh);
        double whiteRatio = (double) whitePixels / ((double)thresh.rows() * (double)thresh.cols());

        if (whiteRatio > 0.5) {
            Core.bitwise_not(thresh, thresh);
        }

        Mat kernel = Imgproc.getStructuringElement(Imgproc.MORPH_RECT, new Size(5, 5));
        Mat clean = new Mat();
        Imgproc.morphologyEx(thresh, clean, Imgproc.MORPH_CLOSE, kernel);
        Imgproc.morphologyEx(clean, clean, Imgproc.MORPH_OPEN, kernel);

        List<MatOfPoint> contours = new ArrayList<MatOfPoint>();
        Mat hierarchy = new Mat();
        Imgproc.findContours(clean, contours, hierarchy, Imgproc.RETR_EXTERNAL, Imgproc.CHAIN_APPROX_SIMPLE);

        if (contours.isEmpty()) {
            releaseAll(image, gray, thresh, kernel, clean, hierarchy);
            return "Uncertain";
        }

        double maxArea = 0.0;
        MatOfPoint largestContour = null;
        for (MatOfPoint contour : contours) {
            double area = Imgproc.contourArea(contour);
            if (area > maxArea) {
                maxArea = area;
                largestContour = contour;
            }
        }

        if (largestContour == null) {
            releaseAll(image, gray, thresh, kernel, clean, hierarchy);
            return "Uncertain";
        }

        RotatedRect rect = Imgproc.minAreaRect(new MatOfPoint2f(largestContour.toArray()));
        double w = rect.size.width;
        double h = rect.size.height;
        double aspectRatio = Math.max(w, h) / Math.min(w, h);

        Point[] box = new Point[4];
        rect.points(box);
        Point[] boxOrdered = sortCorners(box);

        double width = distance(boxOrdered[0], boxOrdered[1]);
        double height = distance(boxOrdered[0], boxOrdered[3]);

        String result;
        if (aspectRatio < 1.2) {
            result = "Square";
        } else {
            //  edge angles
            List<Double> edgeAngles = new ArrayList<Double>();
            for (int i = 0; i < 4; i++) {
                Point p1 = boxOrdered[i];
                Point p2 = boxOrdered[(i + 1) % 4];
                double dx = p2.x - p1.x;
                double dy = p2.y - p1.y;
                double angle = Math.toDegrees(Math.atan2(dy, dx)) % 180.0;
                if (angle < 0) angle += 180.0;
                edgeAngles.add(Double.valueOf(angle));
            }

            boolean hasHorizontal = false;
            for (int i = 0; i < edgeAngles.size(); i++) {
                double a = edgeAngles.get(i).doubleValue();
                if (a < 10.0 || a > 170.0) { hasHorizontal = true; break; }
            }

            boolean hasVertical = false;
            for (int i = 0; i < edgeAngles.size(); i++) {
                double a = edgeAngles.get(i).doubleValue();
                if (a >= 80.0 && a <= 100.0) { hasVertical = true; break; }
            }

            if (hasHorizontal && hasVertical) {
                result = width > height ? "Landscape" : "Portrait";
            } else {
                result = "Uncertain";
            }
        }

        releaseAll(image, gray, thresh, kernel, clean, hierarchy);
        return result;
    }

    private static void releaseAll(Mat... mats) {
        for (Mat m : mats) {
            if (m != null) m.release();
        }
    }

    public static Point[] sortCorners(Point[] points) {
        // API-22

        // sort by (x + y)
        Arrays.sort(points, new Comparator<Point>() {
            public int compare(Point p1, Point p2) {
                double s1 = p1.x + p1.y;
                double s2 = p2.x + p2.y;
                return s1 < s2 ? -1 : (s1 > s2 ? 1 : 0);
            }
        });
        Point[] sorted = new Point[4];
        sorted[0] = points[0];
        sorted[2] = points[3];

        // sort by (y - x)
        Arrays.sort(points, new Comparator<Point>() {
            public int compare(Point p1, Point p2) {
                double d1 = p1.y - p1.x;
                double d2 = p2.y - p2.x;
                return d1 < d2 ? -1 : (d1 > d2 ? 1 : 0);
            }
        });
        sorted[1] = points[0];
        sorted[3] = points[3];

        return sorted;
    }

    public static double distance(Point p1, Point p2) {
        return Math.hypot(p2.x - p1.x, p2.y - p1.y);
    }

    public static boolean isImageFile(String filename) {
        String lower = filename.toLowerCase(Locale.US);
        return lower.endsWith(".png") || lower.endsWith(".jpg") || lower.endsWith(".jpeg");
    }

    
}
