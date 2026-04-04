from dataclasses import dataclass
from datetime import timedelta
from urllib.parse import urlsplit, urlunsplit

from asgiref.sync import async_to_sync
from django.conf import settings
from livekit import api
from livekit.protocol import egress as lk_egress
from livekit.protocol import models as lk_models
from livekit.protocol import room as lk_room


def url_to_http(url: str) -> str:
    if url.startswith("ws://"):
        return url.replace("ws://", "http://", 1)
    if url.startswith("wss://"):
        return url.replace("wss://", "https://", 1)
    return url


@dataclass
class LiveKitService:
    url: str = settings.LIVEKIT_URL
    api_key: str = settings.LIVEKIT_API_KEY
    api_secret: str = settings.LIVEKIT_API_SECRET

    _ALL_PUBLISH_SOURCES = (
        "camera",
        "microphone",
        "screen_share",
        "screen_share_audio",
    )

    def _api_url_candidates(self) -> list[str]:
        primary = url_to_http(self.url or "")
        if not primary:
            return [primary]
        candidates = [primary]
        parsed = urlsplit(primary)
        if parsed.scheme.lower() == "https":
            downgraded = urlunsplit(
                ("http", parsed.netloc, parsed.path, parsed.query, parsed.fragment),
            )
            if downgraded not in candidates:
                candidates.append(downgraded)
        return candidates

    async def _run_with_api_fallback(self, operation):
        last_exc = None
        candidates = self._api_url_candidates()
        for idx, api_url in enumerate(candidates):
            client = api.LiveKitAPI(api_url, self.api_key, self.api_secret)
            try:
                return await operation(client)
            except Exception as exc:
                last_exc = exc
                if idx + 1 >= len(candidates):
                    raise
            finally:
                await client.aclose()
        if last_exc is not None:
            raise last_exc

    def _track_source_enum(self, source: str):
        normalized = (source or "").strip().lower()
        mapping = {
            "camera": lk_models.TrackSource.CAMERA,
            "microphone": lk_models.TrackSource.MICROPHONE,
            "screen_share": lk_models.TrackSource.SCREEN_SHARE,
            "screen_share_audio": lk_models.TrackSource.SCREEN_SHARE_AUDIO,
        }
        return mapping.get(normalized)

    async def _create_room_async(self, room_name: str) -> None:
        client = api.LiveKitAPI(url_to_http(self.url), self.api_key, self.api_secret)
        try:
            await client.room.create_room(
                api.CreateRoomRequest(name=room_name, empty_timeout=10 * 60),
            )
        finally:
            await client.aclose()

    def create_room(self, room_name: str) -> None:
        async_to_sync(self._create_room_async)(room_name)

    async def _delete_room_async(self, room_name: str) -> None:
        client = api.LiveKitAPI(url_to_http(self.url), self.api_key, self.api_secret)
        try:
            await client.room.delete_room(api.DeleteRoomRequest(room=room_name))
        finally:
            await client.aclose()

    def delete_room(self, room_name: str) -> None:
        async_to_sync(self._delete_room_async)(room_name)

    async def _list_participants_async(self, room_name: str):
        client = api.LiveKitAPI(url_to_http(self.url), self.api_key, self.api_secret)
        try:
            response = await client.room.list_participants(
                lk_room.ListParticipantsRequest(room=room_name),
            )
            return list(response.participants)
        finally:
            await client.aclose()

    def list_participants(self, room_name: str):
        return async_to_sync(self._list_participants_async)(room_name)

    async def _remove_participant_async(self, room_name: str, identity: str) -> None:
        client = api.LiveKitAPI(url_to_http(self.url), self.api_key, self.api_secret)
        try:
            await client.room.remove_participant(
                lk_room.RoomParticipantIdentity(room=room_name, identity=identity),
            )
        finally:
            await client.aclose()

    def remove_participant(self, room_name: str, identity: str) -> None:
        async_to_sync(self._remove_participant_async)(room_name, identity)

    async def _update_participant_name_async(
        self,
        room_name: str,
        identity: str,
        *,
        name: str,
    ) -> None:
        update = lk_room.UpdateParticipantRequest(
            room=room_name,
            identity=identity,
            name=name,
        )
        client = api.LiveKitAPI(url_to_http(self.url), self.api_key, self.api_secret)
        try:
            await client.room.update_participant(update)
        finally:
            await client.aclose()

    def update_participant_name(
        self,
        room_name: str,
        identity: str,
        *,
        name: str,
    ) -> None:
        async_to_sync(self._update_participant_name_async)(
            room_name,
            identity,
            name=name,
        )

    async def _update_participant_metadata_async(
        self,
        room_name: str,
        identity: str,
        *,
        metadata: str,
    ) -> None:
        update = lk_room.UpdateParticipantRequest(
            room=room_name,
            identity=identity,
            metadata=metadata,
        )
        client = api.LiveKitAPI(url_to_http(self.url), self.api_key, self.api_secret)
        try:
            await client.room.update_participant(update)
        finally:
            await client.aclose()

    def update_participant_metadata(
        self,
        room_name: str,
        identity: str,
        *,
        metadata: str,
    ) -> None:
        async_to_sync(self._update_participant_metadata_async)(
            room_name,
            identity,
            metadata=metadata,
        )

    async def _update_participant_permissions_async(
        self,
        room_name: str,
        identity: str,
        *,
        can_publish: bool,
        can_subscribe: bool,
        can_publish_data: bool,
        can_publish_sources: list[str] | None,
        can_update_metadata: bool = True,
    ) -> None:
        sources = can_publish_sources or list(self._ALL_PUBLISH_SOURCES)
        enums = []
        for source in sources:
            enum_source = self._track_source_enum(source)
            if enum_source is not None:
                enums.append(enum_source)

        permission = lk_models.ParticipantPermission(
            can_publish=can_publish,
            can_subscribe=can_subscribe,
            can_publish_data=can_publish_data,
            can_publish_sources=enums,
            can_update_metadata=can_update_metadata,
        )
        update = lk_room.UpdateParticipantRequest(
            room=room_name,
            identity=identity,
            permission=permission,
        )

        client = api.LiveKitAPI(url_to_http(self.url), self.api_key, self.api_secret)
        try:
            await client.room.update_participant(update)
        finally:
            await client.aclose()

    def update_participant_permissions(
        self,
        room_name: str,
        identity: str,
        *,
        can_publish: bool,
        can_subscribe: bool,
        can_publish_data: bool,
        can_publish_sources: list[str] | None,
        can_update_metadata: bool = True,
    ) -> None:
        async_to_sync(self._update_participant_permissions_async)(
            room_name,
            identity,
            can_publish=can_publish,
            can_subscribe=can_subscribe,
            can_publish_data=can_publish_data,
            can_publish_sources=can_publish_sources,
            can_update_metadata=can_update_metadata,
        )

    async def _mute_participant_track_sources_async(
        self,
        room_name: str,
        identity: str,
        *,
        track_sources: list[str],
        muted: bool,
    ) -> None:
        enums = {
            self._track_source_enum(source)
            for source in track_sources
        }
        enums.discard(None)
        if not enums:
            return

        client = api.LiveKitAPI(url_to_http(self.url), self.api_key, self.api_secret)
        try:
            participant = await client.room.get_participant(
                lk_room.RoomParticipantIdentity(room=room_name, identity=identity),
            )
            for track in participant.tracks:
                if track.source not in enums:
                    continue
                await client.room.mute_published_track(
                    lk_room.MuteRoomTrackRequest(
                        room=room_name,
                        identity=identity,
                        track_sid=track.sid,
                        muted=muted,
                    ),
                )
        finally:
            await client.aclose()

    def mute_participant_track_sources(
        self,
        room_name: str,
        identity: str,
        *,
        track_sources: list[str],
        muted: bool = True,
    ) -> None:
        async_to_sync(self._mute_participant_track_sources_async)(
            room_name,
            identity,
            track_sources=track_sources,
            muted=muted,
        )

    def create_participant_token(
        self,
        *,
        identity: str,
        room_name: str,
        name: str | None = None,
        can_publish: bool = True,
        can_subscribe: bool = True,
        can_publish_data: bool = True,
        can_publish_sources: list[str] | None = None,
        can_update_own_metadata: bool = True,
    ) -> str:
        token = api.AccessToken(self.api_key, self.api_secret)
        token.with_identity(identity)
        if name:
            token.with_name(name)
        token.with_ttl(timedelta(hours=8))
        token.with_grants(
            api.VideoGrants(
                room_join=True,
                room=room_name,
                can_publish=can_publish,
                can_subscribe=can_subscribe,
                can_publish_data=can_publish_data,
                can_publish_sources=can_publish_sources,
                can_update_own_metadata=can_update_own_metadata,
            )
        )
        return token.to_jwt()

    async def _start_room_composite_egress_to_file_async(
        self,
        room_name: str,
        filepath: str,
        *,
        layout: str = "grid",
    ):
        request = lk_egress.RoomCompositeEgressRequest(
            room_name=room_name,
            layout=layout,
            file_outputs=[
                lk_egress.EncodedFileOutput(
                    filepath=filepath,
                    file_type=lk_egress.MP4,
                )
            ],
            preset=lk_egress.H264_1080P_30,
        )
        async def _operation(client):
            return await client.egress.start_room_composite_egress(request)

        return await self._run_with_api_fallback(_operation)

    def start_room_composite_egress_to_file(
        self,
        room_name: str,
        filepath: str,
        *,
        layout: str = "grid",
    ):
        return async_to_sync(self._start_room_composite_egress_to_file_async)(
            room_name,
            filepath,
            layout=layout,
        )

    async def _list_egress_async(
        self,
        *,
        room_name: str = "",
        egress_id: str = "",
        active: bool = False,
    ):
        request = lk_egress.ListEgressRequest(
            room_name=room_name,
            egress_id=egress_id,
            active=active,
        )
        async def _operation(client):
            response = await client.egress.list_egress(request)
            return list(response.items)

        return await self._run_with_api_fallback(_operation)

    def list_egress(
        self,
        *,
        room_name: str = "",
        egress_id: str = "",
        active: bool = False,
    ):
        return async_to_sync(self._list_egress_async)(
            room_name=room_name,
            egress_id=egress_id,
            active=active,
        )

    async def _stop_egress_async(self, egress_id: str):
        request = lk_egress.StopEgressRequest(egress_id=egress_id)
        async def _operation(client):
            return await client.egress.stop_egress(request)

        return await self._run_with_api_fallback(_operation)

    def stop_egress(self, egress_id: str):
        return async_to_sync(self._stop_egress_async)(egress_id)
