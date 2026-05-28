package md.utm.cloudapp.messages

import org.springframework.http.HttpStatus
import org.springframework.http.ResponseEntity
import org.springframework.web.bind.annotation.GetMapping
import org.springframework.web.bind.annotation.PostMapping
import org.springframework.web.bind.annotation.RequestBody
import org.springframework.web.bind.annotation.RequestMapping
import org.springframework.web.bind.annotation.RestController

data class CreateMessageRequest(val text: String)

@RestController
@RequestMapping("/messages")
class MessagesController(private val repo: MessageRepository) {

    @GetMapping
    fun list(): List<Message> = repo.findAll()

    @PostMapping
    fun create(@RequestBody body: CreateMessageRequest): ResponseEntity<Message> {
        if (body.text.isBlank()) {
            return ResponseEntity.badRequest().build()
        }
        return ResponseEntity.status(HttpStatus.CREATED).body(repo.insert(body.text))
    }
}
