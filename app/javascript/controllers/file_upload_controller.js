import { Controller } from "@hotwired/stimulus"

export default class extends Controller {
  validateFile(event) {
    const file = event.target.files[0]
    if (file) {
      console.log('File selected:', file.name)
      if (!file.type.includes('pdf')) {
        alert('Please select a PDF file')
        event.target.value = ''
      }
    }
  }
}
