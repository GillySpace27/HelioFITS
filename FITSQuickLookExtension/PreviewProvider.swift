import QuickLook
import WebKit
import Quartz

class PreviewProvider: QLPreviewProvider {

    func providePreview(for request: QLFilePreviewRequest, completionHandler: @escaping (QLPreviewReply?, Error?) -> Void) {
        let url = request.fileURL
        
        // Fetch the list of HDUs from the Flask server
        listHDUsForFITSFile(url: url) { hduList, error in
            guard let hduList = hduList, error == nil else {
                completionHandler(nil, error)
                return
            }

            // Create a web-based preview interface showing the list of HDUs
            var html = "<html><body>"
            html += "<h1>Select HDU</h1><ul>"

            for hdu in hduList {
                html += "<li><a href=\"#\" onclick=\"fetchPreview('\(hdu)');\">\(hdu)</a></li>"
            }

            html += """
            </ul>
            <img id="previewImage" src="" style="max-width:100%;">
            <script>
            function fetchPreview(hdu) {
                fetch('/preview?file=' + encodeURIComponent('\(url.path)') + '&extname=' + hdu)
                .then(response => response.json())
                .then(data => {
                    document.getElementById('previewImage').src = 'data:image/png;base64,' + data.image_base64;
                });
            }
            </script></body></html>
            """

            if let data = html.data(using: .utf8) {
                let previewReply = QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: 800, height: 600)) { reply in
                    return data
                }
                completionHandler(previewReply, nil)
            } else {
                completionHandler(nil, NSError(domain: "com.example.fits", code: 0, userInfo: [NSLocalizedDescriptionKey: "Failed to convert HTML to Data"]))
            }
        }
    }
    
    func listHDUsForFITSFile(url: URL, completion: @escaping ([String]?, Error?) -> Void) {
        // Create the URL to interact with the Flask server's list_extnames endpoint
        let serverURL = URL(string: "http://127.0.0.1:5000/list_extnames")!

        var request = URLRequest(url: serverURL)
        request.httpMethod = "POST"
        
        // Create multipart/form-data body to send file data
        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let httpBody = createBody(with: ["file": url], boundary: boundary)
        request.httpBody = httpBody

        // Use URLSession to make the request
        URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data = data, error == nil else {
                completion(nil, error)
                return
            }
            do {
                if let jsonResponse = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                   let extnames = jsonResponse["extnames"] as? [String] {
                    completion(extnames, nil)
                } else {
                    completion(nil, NSError(domain: "com.example.fits", code: 0, userInfo: [NSLocalizedDescriptionKey: "Invalid response from server"]))
                }
            } catch {
                completion(nil, error)
            }
        }.resume()
    }

    func createBody(with parameters: [String: URL], boundary: String) -> Data {
        var body = Data()
        
        for (key, fileURL) in parameters {
            let filename = fileURL.lastPathComponent
            let mimetype = "application/fits"
            do {
                let fileData = try Data(contentsOf: fileURL)
                body.append("--\(boundary)\r\n")
                body.append("Content-Disposition: form-data; name=\"\(key)\"; filename=\"\(filename)\"\r\n")
                body.append("Content-Type: \(mimetype)\r\n\r\n")
                body.append(fileData)
                body.append("\r\n")
            } catch {
                print("Error reading file: \(error)")
            }
        }
        
        body.append("--\(boundary)--\r\n")
        return body
    }
}

extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}
